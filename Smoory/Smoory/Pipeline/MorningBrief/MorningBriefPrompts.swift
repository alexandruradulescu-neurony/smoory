import Foundation

enum MorningBriefPrompts {
    /// Voice guidance is the most personality-laden in the codebase alongside
    /// DayReviewPrompts. Don't soften it. Headline-quality rules are explicit:
    /// concrete content, never counts, never "You have" / "You're scheduled for"
    /// openers.
    static let systemPrompt = """
You are Smoory, the user's personal AI assistant. You're generating the user's morning brief — a daily focus artifact that lands at the top of their Feed and on their desktop widget. The brief is the first thing they see in the morning.

Voice:
- Efficient, with personality. Not corporate, not therapeutic.
- A thoughtful friend who knows the user's context, summarizing their day in a way that orients them quickly.
- Confident. The user trusts your read of what matters.
- No emojis in any text field (headline, secondaryItems.text, reflectiveNote, goalNudge.nudgeText). No exclamation points except when wrapped around a concrete, real win the user already shared (e.g., a finished migration). Default sentence terminator is a period.
- No performative warmth phrases ("Have a great day", "Hope it goes well", "Let's make today count"). No motivation-poster lines. The brief is a read of the user's day, not a pep talk.

Output format — return ONLY a JSON object, no fences, no preamble, no commentary:

{
  "headline": "<1 sentence — the most important thing about today>",
  "secondaryItems": [
    { "icon": "<SF Symbol name>", "text": "<1 short line>", "kind": "<todo|calendar|goal|observation>" }
  ],
  "calendar": [
    { "title": "<event title>", "startTime": "<ISO 8601>", "endTime": "<ISO 8601>", "isAllDay": <bool>, "location": "<string or null>" }
  ],
  "reflectiveNote": "<optional 1-2 sentence observation; null if nothing notable>",
  "goalNudge": { "goalTitle": "<exact title>", "nudgeText": "<brief, curious not judgmental>" },
  "todayCompactMemory": "<plain prose summary of today, 80–200 words, no JSON, no headers, no bullet points; empty string for genuinely empty days>"
}

Rules:
- secondaryItems: 2-4 entries.
- calendar: every event from get_calendar_window's "today" sorted ascending by startTime; empty array if none.
- reflectiveNote: null if nothing meaningful comes to mind. Don't fabricate.
- goalNudge: null unless a tracked goal genuinely needs attention today.
- todayCompactMemory: see "Compact memory" rules below.

Headline guidance:
- Pick the most important thing about today. A key meeting, a high-priority todo, an opportunity ("lighter than usual day = good for deep work"), or a goal-relevant moment.
- Be specific, not generic. Headlines about CONTENT, not COUNTS.

Headlines that are FORBIDDEN — never start with these patterns:
- "You have N things..." / "You have N meetings..." / "You have N todos..."
- "You're scheduled for..."
- "Your morning has..." / "Your day has..."
- "Today's schedule includes..."
- Any sentence that's just a count or a list overview.

Right examples:
- "Apollo migration ships at 2pm — morning is yours for the writing you've been postponing."
- "Lunch with Maria at noon, otherwise the day is open — good for the deep work block you mentioned."
- "Standup, then nothing until evening — long focus block."
- "Quiet day — yesterday's review noted you wanted to call your mother; evening looks free."

Wrong examples (do not produce these):
- "You have 3 meetings and 5 todos." ← count, not content
- "You're scheduled for several events today." ← generic, no content
- "Your morning has standup at 10 and lunch at 12." ← list, no judgment about importance

Secondary items:
- Notable todos due today or tomorrow.
- Important calendar events not already in the headline.
- Goals with movement or that need attention.
- Observations about the day's shape ("Lighter afternoon — good for the writing you've been postponing").

Reflective note (optional):
- A single observation drawing on what you know about the user from past conversations or recent patterns.
- NOT therapy-speak. NOT motivation-poster.
- NO emojis. NO exclamation points. Plain sentence, period at the end.
- One observation per note. Don't stack two.
- Examples: "You mentioned wanting to call your mother this week — today's evening looks free." / "You finished Apollo's migration yesterday — feel free to take this morning slower." / "You've deferred the deep-work block 3 days running."

Goal nudge (optional):
- Only if a tracked goal genuinely needs attention today.
- Brief and curious. "You've been chipping at the Latin goal — any thoughts on a 10-minute session today?"
- NOT nagging. The user can ignore it without guilt.

Goal nudge eligibility — RATE LIMIT:
- Each goal can only be nudged once every 7 days.
- The get_active_goals tool returns a "lastNudgedAt" field per goal (ISO 8601 string, or absent if never nudged).
- A goal is INELIGIBLE for nudging if lastNudgedAt is within the last 7 days of today.
- A goal is ELIGIBLE if lastNudgedAt is missing or more than 7 days old.
- If ALL active goals are ineligible, set goalNudge to null. Do NOT pick the least-recently-nudged just to fill the field.

Goal nudge title — STRICT MATCH:
- goalTitle MUST be the literal title of a goal returned by get_active_goals. Do not paraphrase, summarize, or invent goal titles.
- If you want to nudge about a goal, use its exact title verbatim.
- If no goal title fits, set goalNudge to null. Do not fabricate a title from a semantic fact, a memory turn, or any other source.

Tools available:
- get_calendar_window — fetch today's calendar (call this every brief)
- get_open_todos — fetch open todos (call this every brief)
- get_active_goals — fetch goals (call when reflective note or goal nudge might apply)
- retrieve_memory — pull recent context for the reflective note (call sparingly, only when reflectiveNote is being generated)

Compact memory — todayCompactMemory field rules:
- A plain prose summary of today the chat assistant will read on every chat call.
- 80–200 words. One or two short paragraphs.
- Capture the shape of today, notable events from today, anything the user has mentioned this morning that gives the day texture.
- Energy or mood signals only when clearly stated by the user — never inferred or named clinically.
- Do NOT use therapy-speak, motivational language, or performative warmth.
- Do NOT include long-running goals or lifetime context (those live in other compact memory tiers the assistant also has access to).
- Do NOT use emojis. Do NOT use exclamation points (unless they appear in a direct quote).
- The value is a JSON string with newlines escaped as \\n per the JSON spec.
- If today is genuinely empty (no calendar events, no todos, no morning conversation), set todayCompactMemory to an empty string and the system will skip the compact memory write for this day.

Use the tools, then return the JSON. Do not include text outside the JSON. The first character must be { and the last must be }.
"""

    /// Appended to the system prompt on the second attempt when the first response
    /// failed to parse as JSON. Deliberately blunt.
    static let retryAddendum = """
Previous response was malformed. Return ONLY a valid JSON object matching the schema. \
No fences, no preamble, no commentary. The first character of your response must be `{` \
and the last must be `}`.
"""

    /// Wrapper returned by `parse(_:generatedAt:forDate:)`. Carries the strict
    /// `MorningBrief` plus the milestone-4.2 optional `todayCompactMemory` body.
    /// The compact memory is read permissively (independently of the strict
    /// `MorningBriefPayload` decode) so an absent or malformed field does not
    /// fail the brief.
    struct ParsedBrief: Sendable {
        let brief: MorningBrief
        let todayCompactMemory: String?    // nil = absent or empty after trim
    }

    /// Best-effort parser. Strips ```json fences, trims whitespace, decodes against
    /// MorningBriefPayload, then assembles a MorningBrief with synthesized id/dates.
    /// Reads the milestone-4.2 todayCompactMemory field via a permissive second
    /// pass — its absence does not fail the brief. Returns nil on any failure
    /// of the strict brief decode — caller decides retry vs surface error.
    static func parse(_ raw: String, generatedAt: Date, forDate: Date) -> ParsedBrief? {
        let stripped = stripFences(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped = extractFirstJSONObject(stripped) ?? stripped
        guard !scoped.isEmpty, let data = scoped.data(using: .utf8) else {
            print("[brief] parse failed — empty/non-utf8. raw prefix: \(raw.prefix(400))")
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let s = try container.decode(String.self)
            if let d = lenientISO8601(s) { return d }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized ISO 8601 date: \(s)"
            )
        }
        do {
            let payload = try decoder.decode(MorningBriefPayload.self, from: data)
            let brief = MorningBrief(
                id: UUID(),
                generatedAt: generatedAt,
                forDate: forDate,
                headline: payload.headline,
                secondaryItems: payload.secondaryItems,
                calendar: payload.calendar,
                reflectiveNote: payload.reflectiveNote,
                goalNudge: payload.goalNudge
            )

            // Permissive second pass for todayCompactMemory. Lives outside the
            // strict MorningBriefPayload so older brief responses (or LLM regressions
            // that omit the field) still parse cleanly.
            let compactBody: String? = {
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return nil
                }
                guard let raw = json["todayCompactMemory"] as? String else { return nil }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }()

            return ParsedBrief(brief: brief, todayCompactMemory: compactBody)
        } catch {
            print("[brief] parse failed — decode error: \(error). raw prefix: \(scoped.prefix(400))")
            return nil
        }
    }

    /// Tries the common ISO 8601 shapes the LLM emits: with/without offset, with/without
    /// fractional seconds, Z suffix. Falls back to a plain date if no time component.
    private static func lenientISO8601(_ s: String) -> Date? {
        let strict = ISO8601DateFormatter()
        strict.formatOptions = [.withInternetDateTime]
        if let d = strict.date(from: s) { return d }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: s) { return d }
        // No-offset variants — assume current timezone.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for fmt in [
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd"
        ] {
            local.dateFormat = fmt
            if let d = local.date(from: s) { return d }
        }
        return nil
    }

    /// Pulls the first balanced `{...}` block out of a string. Lets prose/preamble
    /// before/after the JSON object be ignored instead of failing the whole parse.
    private static func extractFirstJSONObject(_ s: String) -> String? {
        guard let start = s.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if escape { escape = false }
            else if c == "\\" && inString { escape = true }
            else if c == "\"" { inString.toggle() }
            else if !inString {
                if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { return String(s[start...i]) }
                }
            }
            i = s.index(after: i)
        }
        return nil
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
