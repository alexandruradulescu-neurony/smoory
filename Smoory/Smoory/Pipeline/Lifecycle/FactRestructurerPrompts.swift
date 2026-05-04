import Foundation

/// System prompt and runtime input/output helpers for the day-end fact
/// restructurer (4.5). Conservative throughout — false-positive refinements
/// destroy good data; false negatives just leave a fact unchanged for another
/// pass to revisit.
enum FactRestructurerPrompts {

    /// Maximum number of operations the restructurer is allowed to propose
    /// per day. Cap protects Feed from a runaway run that proposes 20 edits.
    /// Restructurer-side throttle: even if the LLM emits more, we keep
    /// only the first N.
    static let maxOperationsPerDay = 5

    static let systemPrompt = """
You are reviewing the user's facts in light of the day's chat turns. Propose refinements where the day's evidence makes a fact clearer, more complete, or wrong. Each proposal is REVIEWED by the user before it commits — your job is to flag candidates, not to overwrite memory directly.

Five operations are available:

- "refine" — a single fact's body could be more accurate or more specific given what the user said today. Propose the new body. Keep the original meaning intact.
- "merge" — 2 or 3 facts about the same entity should be one consolidated fact. Propose the merged body and the IDs being collapsed.
- "split" — one existing fact really packs 2 or 3 distinct facts. Propose the split bodies.
- "contradict" — today's evidence makes the fact false. Propose the new replacement body. Different from "refine" because the meaning changed, not just the wording.
- "archive" — this fact was captured today (or recently) but is too transient to keep ("user feels tired tonight", "user mentioned dinner plans"). Propose archival with a brief reason.

Lean toward NO change. Only propose an operation when the day's evidence makes it unambiguous. False positives erode trust — the user has to review every proposal, and a noisy day burns their patience. If a fact is fine as-is, leave it alone.

DO NOT:
- Refine purely for stylistic reasons. "User likes coffee" → "User loves coffee" is NOT acceptable; the meaning shifted without evidence.
- Merge facts about different entities just because they sound similar.
- Split facts that are coherent single statements.
- Mark something as contradiction unless today's evidence is direct (the user said the opposite, or stated a change).
- Archive facts the user has user_confirmed = true unless today's evidence makes them no longer durable.
- Propose more than \(maxOperationsPerDay) operations total. Pick the most important ones.

Output strict JSON. No prose, no fences, no commentary. Schema:
{"operations": [
  {"op": "refine", "oldFactID": "<UUID>", "newBody": "<string>", "reason": "<short>"},
  {"op": "merge", "oldFactIDs": ["<UUID>", "<UUID>"], "newBody": "<string>", "reason": "<short>"},
  {"op": "split", "oldFactID": "<UUID>", "newBodies": ["<string>", "<string>"], "reason": "<short>"},
  {"op": "contradict", "oldFactID": "<UUID>", "newBody": "<string>", "reason": "<short>"},
  {"op": "archive", "oldFactID": "<UUID>", "reason": "<string>"}
]}

If nothing is worth refining, return {"operations": []}. The first character of your response must be { and the last must be }.
"""

    /// Inputs the restructurer sees per pass. Today's chat turns are the
    /// fresh evidence; today's facts are the candidates for restructuring;
    /// recent past facts (last ~7 days, capped) provide cross-day context
    /// so a contradiction across days is recognized.
    struct RestructuringInputs: Sendable {
        let now: Date
        let todayChatTurns: [MemoryTurn]    // chronological
        let todayFacts: [SemanticFact]      // active, non-private
        let recentPastFacts: [SemanticFact] // active, non-private, last 7 days excluding today
    }

    static func userMessage(_ inputs: RestructuringInputs) -> String {
        var lines: [String] = []
        lines.append("Today is \(formatDate(inputs.now)).")
        lines.append("")

        if !inputs.todayChatTurns.isEmpty {
            lines.append("# Today's chat turns (chronological)")
            for turn in inputs.todayChatTurns.suffix(50) {
                let role = turn.role == .user ? "User" : "Assistant"
                let stamp = turn.createdAt.formatted(.dateTime.hour().minute())
                lines.append("[\(stamp)] \(role): \(truncate(turn.content, max: 400))")
            }
            lines.append("")
        }

        if !inputs.todayFacts.isEmpty {
            lines.append("# Today's facts (eligible for restructuring)")
            for fact in inputs.todayFacts {
                let confirmed = fact.userConfirmed ? "[user-confirmed]" : "[auto]"
                lines.append("- ID \(fact.id) \(confirmed): \(fact.body)")
            }
            lines.append("")
        }

        if !inputs.recentPastFacts.isEmpty {
            lines.append("# Recent past facts (read-only context, do NOT propose ops on these)")
            for fact in inputs.recentPastFacts.prefix(30) {
                lines.append("- \(fact.body)")
            }
            lines.append("")
        }

        lines.append("Return only the JSON object. Lean toward fewer proposals.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Parsed output

    struct ParsedOperation: Sendable {
        let op: FactRewriteOp
        let oldFactIDs: [UUID]
        let newBodies: [String]
        let reason: String?
    }

    struct ParsedOperations: Sendable {
        let operations: [ParsedOperation]
    }

    /// Permissive parser: strips fences, decodes the operations array.
    /// Returns empty on any failure rather than throwing — a malformed
    /// response should not block the day-review summary from persisting.
    /// Caps at `maxOperationsPerDay` post-parse.
    static func parse(_ raw: String) -> ParsedOperations {
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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let opsRaw = json["operations"] as? [[String: Any]]
        else {
            print("[restructurer] parse failed; raw prefix: \(unwrapped.prefix(200))")
            return ParsedOperations(operations: [])
        }

        let ops: [ParsedOperation] = opsRaw.compactMap { dict in
            guard let opStr = dict["op"] as? String,
                  let op = FactRewriteOp(rawValue: opStr)
            else { return nil }

            let reason = dict["reason"] as? String

            switch op {
            case .refine, .contradict:
                guard let oldStr = dict["oldFactID"] as? String,
                      let oldID = UUID(uuidString: oldStr),
                      let newBody = dict["newBody"] as? String, !newBody.isEmpty
                else { return nil }
                return ParsedOperation(op: op, oldFactIDs: [oldID], newBodies: [newBody], reason: reason)

            case .merge:
                guard let oldStrs = dict["oldFactIDs"] as? [String],
                      oldStrs.count >= 2,
                      let newBody = dict["newBody"] as? String, !newBody.isEmpty
                else { return nil }
                let ids = oldStrs.compactMap(UUID.init(uuidString:))
                guard ids.count == oldStrs.count else { return nil }
                return ParsedOperation(op: op, oldFactIDs: ids, newBodies: [newBody], reason: reason)

            case .split:
                guard let oldStr = dict["oldFactID"] as? String,
                      let oldID = UUID(uuidString: oldStr),
                      let newBodies = dict["newBodies"] as? [String],
                      newBodies.count >= 2,
                      newBodies.allSatisfy({ !$0.isEmpty })
                else { return nil }
                return ParsedOperation(op: op, oldFactIDs: [oldID], newBodies: newBodies, reason: reason)

            case .archive:
                guard let oldStr = dict["oldFactID"] as? String,
                      let oldID = UUID(uuidString: oldStr)
                else { return nil }
                let why = (dict["reason"] as? String) ?? "marked transient"
                return ParsedOperation(op: op, oldFactIDs: [oldID], newBodies: [], reason: why)
            }
        }

        let capped = Array(ops.prefix(maxOperationsPerDay))
        return ParsedOperations(operations: capped)
    }

    // MARK: - Helpers

    private static func formatDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).year().month(.wide).day())
    }

    private static func truncate(_ s: String, max: Int) -> String {
        s.count <= max ? s : (s.prefix(max - 1) + "…")
    }
}
