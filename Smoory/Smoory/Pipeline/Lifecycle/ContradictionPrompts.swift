import Foundation

/// System prompt + builders for the LLM-driven contradiction-check pass used by
/// `ContradictionDetector`. Conservative on purpose: false positives spam the
/// Feed and erode the user's trust in supersession proposals; missed
/// contradictions stay in the database where the user can clean up via Memory
/// inspection's manual deletion. Lean toward false negatives.
enum ContradictionPrompts {
    static let contradictionSystemPrompt = """
You are determining which existing facts about a user (if any) genuinely contradict a new fact.

CONTRADICTION means: both facts cannot be simultaneously true about the user. The new fact would replace or override the old.

Examples of CONTRADICTIONS (return as conflicting):
- Old: "User lives in Bucharest" / New: "User lives in Cluj"
- Old: "User is vegetarian" / New: "User stopped being vegetarian"
- Old: "User's partner is named Maria" / New: "User's partner is named Sofia"
- Old: "User works at Smoory" / New: "User left Smoory"

NOT contradictions (do NOT return as conflicting):
- Old: "User lives in Bucharest" / New: "User is in Bucharest" (more specific, not contradicting)
- Old: "User likes coffee" / New: "User had a coffee" (related, not contradicting)
- Old: "User has goal: learn Latin" / New: "User has goal: learn Italian" (parallel, both can be true)
- Old: "User's partner is Maria" / New: "User mentioned a colleague named Sofia" (different relationships)
- Old: "User exercises in the morning" / New: "User exercised this evening" (one-off, not lifestyle)
- Old: "User is 39 years old" / New: "User had birthday" (related, not contradicting — though "User is now 40" WOULD contradict)

If uncertain, lean toward NOT contradicting. False positives are worse than false negatives — a missed contradiction stays in the database; a false-positive supersession destroys good data.

Output: JSON array of indices, no preamble, no fences. Empty array if none contradict. The first character must be [ and the last must be ].

Examples:
- No contradictions: []
- Index 2 contradicts: [2]
- Indices 0 and 3 contradict: [0, 3]
"""

    /// Builds the user-message portion containing the new fact and the indexed
    /// shortlist. Order is the same as `candidates` so the LLM's returned
    /// indices map back cleanly.
    static func buildUserMessage(newFactBody: String, candidates: [SemanticFact]) -> String {
        var lines: [String] = []
        lines.append("New fact: \"\(newFactBody)\"")
        lines.append("")
        lines.append("Existing facts:")
        for (idx, fact) in candidates.enumerated() {
            lines.append("[\(idx)] \(fact.body)")
        }
        lines.append("")
        lines.append("Return only the JSON array.")
        return lines.joined(separator: "\n")
    }

    /// Permissive parser: strips ``` fences, trims whitespace, decodes a JSON
    /// array of integers. Returns [] on any failure — the detector treats
    /// "no contradictions" and "couldn't parse" identically (defensive: better
    /// to miss a contradiction than to silently destroy a good fact).
    static func parseIndices(_ raw: String) -> [Int] {
        let stripped = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let unwrapped: String
        if stripped.hasPrefix("```") {
            // Drop ```json header (or just ```) and trailing ```.
            let afterFirstNewline = stripped.drop { $0 != "\n" }.dropFirst()
            let withoutFooter = afterFirstNewline.hasSuffix("```")
                ? afterFirstNewline.dropLast(3)
                : afterFirstNewline
            unwrapped = String(withoutFooter).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            unwrapped = stripped
        }

        guard let data = unwrapped.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([Int].self, from: data)
        else {
            print("[lifecycle] contradiction-check parse failed; raw prefix: \(raw.prefix(200))")
            return []
        }
        return parsed
    }
}
