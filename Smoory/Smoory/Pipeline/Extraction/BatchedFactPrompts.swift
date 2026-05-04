import Foundation

/// Prompts for the batched fact extractor (4.4). Two prompts:
///
/// - `salienceSystemPrompt` — tiny pre-check that decides whether a window of
///   chat turns contains anything memory-worthy. Cheap (.fast tier). False
///   positives waste a heavy-tier call; false negatives lose the batch until
///   the next trigger fires.
///
/// - `extractionSystemPrompt` — heavy-tier extraction that produces the
///   `.fact`-only candidates the Feed will surface for user review. Sees the
///   recent active facts as context so multi-turn arcs ("Maria's my partner"
///   then later "she's a doctor at City Hospital") get coherent facts rather
///   than fragments.
enum BatchedFactPrompts {

    // MARK: - Salience gate

    /// Conservative gate. "Worthy" means durable identity, preferences,
    /// relationships, recurring commitments, ongoing projects, learned skills,
    /// important people. Lean toward `true` — the cost of a false positive is
    /// one wasted heavy-tier call; the cost of a false negative is delayed
    /// fact capture (which the next trigger usually fixes).
    static let salienceSystemPrompt = """
You are deciding whether a window of chat turns contains anything worth committing to long-term memory about the user.

Memory-worthy means: durable identity facts, stable preferences, long-running relationships, recurring commitments, ongoing projects, learned skills, important people. Things the assistant should remember 6 months from now.

NOT memory-worthy: transient state ("I'm tired today"), one-off reactions, small talk, follow-up clarifications without new content, the assistant's own answers, short pleasantries.

If uncertain, lean toward worthy = true. A false positive wastes one extraction call; a false negative delays fact capture.

Output ONLY valid JSON of the form:
{"worthy": true | false, "reason": "<one short sentence>"}

The first character must be { and the last must be }.
"""

    static func salienceUserMessage(turns: [MemoryTurn]) -> String {
        var lines: [String] = []
        lines.append("Chat turns to review:")
        lines.append("")
        for turn in turns {
            let role = turn.role == .user ? "User" : "Assistant"
            let stamp = turn.createdAt.formatted(.dateTime.hour().minute())
            lines.append("[\(stamp)] \(role): \(truncate(turn.content, max: 280))")
        }
        lines.append("")
        lines.append("Return only the JSON object.")
        return lines.joined(separator: "\n")
    }

    struct SalienceVerdict: Sendable {
        let worthy: Bool
        let reason: String
    }

    /// Permissive parser: strips fences, trims, decodes the {worthy, reason} shape.
    /// Returns `(worthy: true, reason: "parse-failure")` on any failure so an
    /// unparseable response does NOT silently skip extraction. Wasted heavy-tier
    /// call is cheaper than a missed fact.
    static func parseSalience(_ raw: String) -> SalienceVerdict {
        let stripped = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let unwrapped: String
        if stripped.hasPrefix("```") {
            let afterFirstNewline = stripped.drop { $0 != "\n" }.dropFirst()
            let withoutFooter = afterFirstNewline.hasSuffix("```")
                ? afterFirstNewline.dropLast(3)
                : afterFirstNewline
            unwrapped = String(withoutFooter).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            unwrapped = stripped
        }
        guard let data = unwrapped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[batched] salience parse failed; treating as worthy. raw prefix: \(raw.prefix(200))")
            return SalienceVerdict(worthy: true, reason: "parse-failure")
        }
        let worthy = (json["worthy"] as? Bool) ?? true
        let reason = (json["reason"] as? String) ?? ""
        return SalienceVerdict(worthy: worthy, reason: reason)
    }

    // MARK: - Heavy-tier fact extraction

    static let extractionSystemPrompt = """
You are extracting durable facts about the user from a window of chat turns. Output is consumed by a Feed surface where the user reviews each fact before it commits to memory.

Categories — emit ONLY "fact" candidates. Other structured candidates (goals, projects, todos, etc.) come from a different layer; do not emit them.

A "fact" is: a durable semantic statement about the user, their world, or their preferences. Examples: "I'm vegetarian", "I live in Bucharest", "my partner's name is Maria", "I work at Smoory", "I have two kids".

NOT facts: transient state, one-off reactions, the user's todos or goals (those go elsewhere), assistant's own answers, small talk.

You also see RECENTLY-CONSOLIDATED facts as context. Use them to:
- Avoid duplicating something already captured.
- Recognize follow-up details ("she's a doctor" after "my partner is Maria" → write "Maria works as a doctor").
- Notice contradictions only as data points; the contradiction system handles them separately.

Output strict JSON. No prose, no fences, no commentary. Schema:
{"candidates": [
  {"type": "fact",
   "content": "<record-ready third-person statement>",
   "confidence": <0.0-1.0>,
   "user_phrase": "<the literal words from the user that triggered this>"}
]}

Rules:
- If nothing durable is in the window, return {"candidates": []}.
- "content" is a record-ready third-person statement, not a quote.
- "user_phrase" is the literal words from the user that triggered the fact.
- Confidence: ≥0.85 only when the user stated the fact unambiguously.
- One fact per candidate. Don't pack multiple distinct facts into one body.

The first character of your output must be { and the last must be }.
"""

    static func extractionUserMessage(turns: [MemoryTurn], recentFacts: [SemanticFact]) -> String {
        var lines: [String] = []

        if !recentFacts.isEmpty {
            lines.append("# Recently-consolidated facts (avoid duplicating)")
            for fact in recentFacts.prefix(15) {
                lines.append("- \(fact.body)")
            }
            lines.append("")
        }

        lines.append("# Chat turns to extract from")
        for turn in turns {
            let role = turn.role == .user ? "User" : "Assistant"
            let stamp = turn.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            lines.append("[\(stamp)] \(role): \(truncate(turn.content, max: 600))")
        }
        lines.append("")
        lines.append("Return only the JSON.")
        return lines.joined(separator: "\n")
    }

    struct ParsedExtraction: Sendable {
        struct Candidate: Sendable {
            let content: String
            let confidence: Double
            let userPhrase: String
        }
        let candidates: [Candidate]
    }

    /// Permissive parser. Strips fences, decodes the shape; returns empty
    /// candidates on any failure so a malformed extraction doesn't silently
    /// pollute Feed.
    static func parseExtraction(_ raw: String) -> ParsedExtraction {
        let stripped = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let unwrapped: String
        if stripped.hasPrefix("```") {
            let afterFirstNewline = stripped.drop { $0 != "\n" }.dropFirst()
            let withoutFooter = afterFirstNewline.hasSuffix("```")
                ? afterFirstNewline.dropLast(3)
                : afterFirstNewline
            unwrapped = String(withoutFooter).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            unwrapped = stripped
        }

        // First attempt: parse the unwrapped string as-is.
        guard let data = unwrapped.data(using: .utf8) else {
            return ParsedExtraction(candidates: [])
        }
        var jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Fallback: response may have been truncated mid-output by max-tokens
        // limits. Try to recover by scoping to the largest balanced { ... } prefix.
        if jsonObject == nil, let recovered = recoverBalancedJSON(unwrapped) {
            print("[batched] extraction parse: recovered partial JSON (\(unwrapped.count - recovered.count) trailing chars dropped)")
            if let recoveredData = recovered.data(using: .utf8) {
                jsonObject = try? JSONSerialization.jsonObject(with: recoveredData) as? [String: Any]
            }
        }

        guard let json = jsonObject,
              let raw = json["candidates"] as? [[String: Any]] else {
            print("[batched] extraction parse failed; raw prefix: \(unwrapped.prefix(200))")
            return ParsedExtraction(candidates: [])
        }
        let candidates: [ParsedExtraction.Candidate] = raw.compactMap { dict in
            guard
                let content = dict["content"] as? String,
                !content.isEmpty
            else { return nil }
            let confidence = (dict["confidence"] as? Double) ?? 0.7
            let userPhrase = (dict["user_phrase"] as? String) ?? ""
            return ParsedExtraction.Candidate(
                content: content,
                confidence: confidence,
                userPhrase: userPhrase
            )
        }
        return ParsedExtraction(candidates: candidates)
    }

    // MARK: - Helpers

    private static func truncate(_ s: String, max: Int) -> String {
        s.count <= max ? s : (s.prefix(max - 1) + "…")
    }

    /// Recovery path for truncated extraction responses (max-tokens cutoff).
    /// Walks the string and returns the prefix ending at the last balanced
    /// outermost `}`. If the response was cut mid-candidate inside the
    /// candidates array, this trims the partial candidate AND closes the
    /// outer object so the resulting string is parseable. Returns nil if
    /// no balanced prefix exists.
    private static func recoverBalancedJSON(_ s: String) -> String? {
        guard s.hasPrefix("{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var lastBalancedIdx: String.Index?

        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if escape { escape = false }
            else if c == "\\" && inString { escape = true }
            else if c == "\"" { inString.toggle() }
            else if !inString {
                if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { lastBalancedIdx = i }
                }
            }
            i = s.index(after: i)
        }
        if let end = lastBalancedIdx {
            return String(s[...end])
        }
        // No outer-balanced `}` found. Try to construct a synthetic close:
        // find the last `}` that closes an inner candidate, drop everything
        // after it, then append "]}" to seal off the truncated array.
        if let lastInnerClose = s.lastIndex(of: "}") {
            let prefix = s[...lastInnerClose]
            let synthetic = String(prefix) + "]}"
            return synthetic
        }
        return nil
    }
}
