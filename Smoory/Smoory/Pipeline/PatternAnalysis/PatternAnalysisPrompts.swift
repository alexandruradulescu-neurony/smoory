import Foundation

enum PatternAnalysisPrompts {
    static let systemPrompt = """
You are analyzing the user's last week of scheduled actions to surface patterns the user might find interesting. The user is about to do a weekly review with you and wants observations to ground the conversation.

Voice:
- Observational, not judgmental.
- Specific, not vague. "You completed 87% of morning reminders but only 42% of evening reminders" — not "You seem to do better in the mornings."
- Curious. The patterns are starting points for conversation, not conclusions.

Forbidden patterns:
- Diagnostic-sounding phrasing. NEVER use clinical or psychological framing ("user has ADHD", "user struggles with...", "user shows signs of...", "user seems anxious"). Behavioral observations only.
- Motivational framing ("you're crushing it", "great job", "amazing work"). Smoory is not a coach.
- Vague trends without numbers ("you seem more productive", "things are going well"). Always cite specific counts or percentages.

Output format — return ONLY a JSON object, no fences, no preamble, no commentary:

{
  "observations": [
    { "observation": "<1-2 sentence prose>", "kind": "<completion|deferral|timing|absence|rhythm>", "evidence": "<the data backing it, brief>" }
  ],
  "durableInsights": [
    { "factText": "<phrased as a fact about the user, third person>", "confidence": <0.0-1.0>, "derivedFromObservationIndices": [0, 2] }
  ]
}

Observations rules:
- 3-7 observations is the right range. Fewer than 3 is too thin; more than 7 is overwhelming.
- Mix kinds. Don't produce 5 deferral observations and nothing else. Aim for at least 3 distinct kinds when the data supports it.
- Reference specific data ("4 of 7 nights", "3 days running", "12 of 14 reminders") not vague trends.
- evidence field is brief (~10 words) — the raw count or comparison that backs the observation.

Durable insights rules:
- A subset of observations rephrased as durable facts about the user. ONLY include if confidence is genuinely high (≥ 0.7) AND the pattern is likely to persist beyond this week.
- Format: "User is X" or "User tends to X" — same shape as semantic_facts entries. Third person.
- 0-3 insights total. Often 0 — a single week is rarely enough signal for durable claims.
- NOT diagnostic. NOT motivational. Behavioral observations only.
- derivedFromObservationIndices are 0-based positions in the observations array.

Sparse-data handling:
- If the week has fewer than 5 actions total, produce 1-2 light observations and zero durable insights.
- If the user did not engage with the system at all (zero completions/skips/postpones), say so directly: one observation noting the absence, kind "absence", durableInsights empty.

Don't fabricate. If a kind genuinely doesn't apply this week (e.g., no rhythm because data is too sparse), skip it.

The first character of your response must be { and the last must be }.
"""

    static let retryAddendum = """
Previous response was malformed. Return ONLY a valid JSON object matching the schema. No fences, no preamble, no commentary. The first character must be `{` and the last must be `}`.
"""

    /// Builds the user message containing the week's stats + anonymized history.
    /// Anonymization: action content text is included (the user wrote it themselves);
    /// no other PII surfaces because the data is already user-only.
    static func buildUserMessage(stats: WeekStats, history: [ScheduledAction], weekStart: Date, weekEnd: Date) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]

        var lines: [String] = []
        lines.append("Week range: \(isoFormatter.string(from: weekStart)) → \(isoFormatter.string(from: weekEnd))")
        lines.append("")
        lines.append("Stats:")
        lines.append("- totalReminders: \(stats.totalReminders)")
        lines.append("- completedReminders: \(stats.completedReminders)")
        lines.append("- skippedReminders: \(stats.skippedReminders)")
        lines.append("- postponedReminders: \(stats.postponedReminders)")
        lines.append("- dayReviewsCompleted: \(stats.dayReviewsCompleted)")
        if let avg = stats.avgUserResponseTime {
            lines.append("- avgUserResponseTime: \(Int(avg))s")
        }
        if let most = stats.mostDeferredAction {
            lines.append("- mostDeferredAction: \"\(most)\"")
        }
        lines.append("")
        lines.append("Action history (kind | status | scheduledFor | deferralCount | content):")
        for action in history.prefix(40) {
            let scheduled = isoFormatter.string(from: action.scheduledFor)
            let content = action.content.isEmpty ? "(no body)" : action.content
            lines.append("- \(action.kind) | \(action.status) | \(scheduled) | defers=\(action.deferralCount) | \(content)")
        }
        if history.count > 40 {
            lines.append("- … and \(history.count - 40) more")
        }
        lines.append("")
        lines.append("Analyze and return JSON only.")
        return lines.joined(separator: "\n")
    }

    /// Best-effort parser. Strips fences, decodes wire payload, maps observation
    /// indices to UUIDs. Returns nil on any failure (caller decides retry vs surface).
    static func parse(_ raw: String, analyzedAt: Date, weekStart: Date, weekEnd: Date, stats: WeekStats) -> PatternAnalysis? {
        let stripped = stripFences(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty, let data = stripped.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(PatternAnalysisPayload.self, from: data) else {
            return nil
        }

        // Materialize observations with UUIDs and keep a wire-index → UUID map so that
        // dropping observations with unknown kinds doesn't shift insight cross-refs.
        // Earlier code did `compactMap` then indexed `observations[idx]`; if any wire
        // entry was dropped, all subsequent insights pointed to the wrong row.
        var observations: [PatternObservation] = []
        var wireIndexToID: [Int: UUID] = [:]
        for (idx, wire) in payload.observations.enumerated() {
            guard let kind = PatternObservation.ObservationKind(rawValue: wire.kind) else { continue }
            let obs = PatternObservation(observation: wire.observation, kind: kind, evidence: wire.evidence)
            observations.append(obs)
            wireIndexToID[idx] = obs.id
        }

        let insights: [DurableInsight] = payload.durableInsights.map { wire in
            let derivedIDs: [UUID] = wire.derivedFromObservationIndices.compactMap { wireIndexToID[$0] }
            return DurableInsight(
                factText: wire.factText,
                confidence: wire.confidence,
                derivedFrom: derivedIDs
            )
        }

        return PatternAnalysis(
            analyzedAt: analyzedAt,
            weekStartedAt: weekStart,
            weekEndedAt: weekEnd,
            stats: stats,
            observations: observations,
            durableInsights: insights
        )
    }

    private static func stripFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let firstNL = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: firstNL)...])
            }
            if t.hasSuffix("```") {
                t = String(t.dropLast(3))
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
