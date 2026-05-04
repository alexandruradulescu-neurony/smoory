import Foundation

/// System prompts and runtime input builders for the three compact memory tiers.
///
/// Voice rules align with milestone 4.0's main-chat prompt: no emojis, no
/// exclamation points (unless quoting the user verbatim), no performative warmth,
/// no therapy-speak. Plain prose. Output is consumed directly by Orchestrator's
/// <compact_memory> block on every chat call, so any drift here surfaces as
/// chatbot voice in the assistant's replies.
enum CompactMemoryPrompts {

    // MARK: - System prompts

    static let todaySystemPrompt = """
You are generating a brief prose summary of the user's current day for the user's AI assistant to use as context. The summary will be injected into every chat the assistant has today, giving the assistant a baseline read of what's going on now.

Voice: a thoughtful friend's brief mental model of the user's day-in-progress.

What to include:
- Notable events from today (what happened earlier, what's coming)
- The general shape of today (busy, light, focused on X)
- Anything the user mentioned this morning that gives the day texture
- Energy or mood signals only when clearly stated by the user — never inferred or named clinically

What to exclude:
- Long-running goals or background context (that's .recent and .overall's job)
- Specific minutiae unrelated to today's flow
- Therapy-speak, motivational language, performative warmth
- Emojis. Exclamation points (unless they appear in a direct quote).

Length: 80–200 words. One or two short paragraphs.

Output: plain prose. No JSON, no headers, no bullet points. The first character is the first word of the summary.

Example structure:
"Monday. Apollo migration ships at 14:00 — the day's centerpiece. Standup at 10, lunch with Maria at Yumi at 12:30. Morning is open until standup. Founder meeting at 17:00, then evening is uncommitted. The user mentioned wanting to call their mother this week; today's evening could fit that."
"""

    static let recentSystemPrompt = """
You are generating a prose summary of the user's recent weeks for the user's AI assistant to use as ongoing context. The summary will be injected into every chat for the next week.

Voice: a thoughtful friend's understanding of where the user is right now in their life — projects, concerns, themes, ongoing relationships.

What to include:
- Active projects and their state ("Apollo migration shipped last week; now planning the Q3 rebuild")
- Recurring meetings, commitments, rhythms ("founder meeting every Monday")
- Recent themes — concerns, patterns, what the user has been preoccupied with
- Important people and their current relevance ("Maria — partner, doctor at City Hospital, mentioned wanting to call her mother")
- Recent goal progress (without nagging)
- Notable events from the past few weeks

What to exclude:
- Lifetime patterns or durable identity (that's .overall's job)
- Today-specific minutiae (that's .today's job)
- Private/sensitive facts that have been flagged private (these are filtered before you see them — if you would have mentioned something the user is sensitive about, you won't have access to it)
- Performative warmth or motivational language
- Therapy-speak or diagnostic phrasing
- Emojis. Exclamation points.

Length: 150–300 words. One to three short paragraphs.

Output: plain prose. No JSON, no headers, no bullet points.

Example structure:
"Apollo migration completed last week — the major project finishing point. The user has turned attention to Q3 architecture. Foundation work continues at Smoory. Recurring rhythm: founder meeting Monday at 17:00, day reviews most evenings (skipped 4 of 7 in the past week — worth noticing if it persists). Reading: The Dispossessed by Le Guin, ~30 pages a day pace. Maria mentioned a contract delay at City Hospital — possibly an ongoing concern. Latin study goal at low priority lately, hasn't been mentioned in 2 weeks."
"""

    static let overallSystemPrompt = """
You are generating a prose summary of the user's durable identity, lifetime patterns, and stable context for the user's AI assistant to use as foundational background. This summary changes slowly — typically once a month. The assistant injects it into every chat.

Voice: a thoughtful friend's read on who the user is, what they value, the structures of their life that don't shift week to week.

What to include:
- Identity facts (name, age, location, occupation, life situation)
- Stable preferences and values (vegetarian, prefers early-morning work, dislikes phone calls)
- Long-running relationships (partner, family members, key colleagues)
- Durable goals and aspirations (not week-to-week todos)
- Behavioral patterns Smoory has observed over time and the user has confirmed
- Ongoing life context (running a business, raising children, in a particular career stage)

What to exclude:
- Anything time-bound to this week or this day
- Anything that's likely to change within 30 days
- Private/sensitive facts (filtered before you see them)
- Diagnostic or clinical phrasing
- Anything the user hasn't confirmed durably (single mentions shouldn't make it here)
- Emojis. Exclamation points.

Length: 300–500 words. Two to four short paragraphs.

Output: plain prose. No JSON, no headers, no bullet points.

Example structure:
"Alexandru, 40, lives in Bucharest, originally from Moreni. Vegetarian. Runs Smoory, a personal AI assistant business. Partner is Maria, a doctor at City Hospital — relationship appears stable and central. Works in Romanian and English; productivity skewed toward early morning hours.

Long-running goals include building Smoory to product-market fit, learning Latin (intermittent priority), and reading 30 pages daily as a discipline. Has demonstrated a pattern of deferring evening commitments more than morning ones — energy winds down by late afternoon.

Founder meeting is a recurring Monday-evening commitment. Day reviews are an established practice when consistent. Calendar is light by default; meetings tend to cluster on Mondays and Wednesdays.

Communication style: direct, prefers brief responses, values honest pushback over performative agreement. Has explicitly preferred Smoory's tone be 'thoughtful friend' rather than chatbot."
"""

    // MARK: - Retry addendum (shared across kinds)

    /// Appended to the system prompt on the second attempt when the first response
    /// is empty, contains JSON or markdown, or falls outside the kind's word-count
    /// bounds. `<N>` / `<M>` are substituted at runtime per kind.
    static func retryAddendum(targetMin: Int, targetMax: Int) -> String {
        """
Previous response was malformed or out of length bounds. Output ONLY the prose summary (no preamble, no JSON, no headers, no markdown). Target word count: \(targetMin)–\(targetMax) words. The first character must be the first word of the summary, and the last character must be a period.
"""
    }

    // MARK: - User message inputs

    struct TodayInputs: Sendable {
        let now: Date
        let calendarEvents: [CalendarEvent]
        let completedTodosToday: [Todo]
        let memoryTurns: [MemoryTurn]    // chronological order, oldest first
        let previousTodayBody: String?
    }

    struct RecentInputs: Sendable {
        let now: Date
        let facts: [SemanticFact]        // last-30d, non-private, non-superseded
        let previousRecentBody: String?
        let previousOverallBody: String?
    }

    struct OverallInputs: Sendable {
        let now: Date
        let facts: [SemanticFact]        // user_confirmed=true, non-private, non-superseded
        let previousOverallBody: String?
        let previousRecentBody: String?
    }

    static func todayUserMessage(_ inputs: TodayInputs) -> String {
        var lines: [String] = []
        lines.append("Today is \(formatDateLong(inputs.now)). Local time: \(formatTime(inputs.now)).")
        lines.append("")

        if let prev = inputs.previousTodayBody, !prev.isEmpty {
            lines.append("# Previous .today summary (regenerate, don't restart from scratch)")
            lines.append(prev)
            lines.append("")
        }

        if !inputs.calendarEvents.isEmpty {
            lines.append("# Today's calendar")
            for event in inputs.calendarEvents {
                let time = event.isAllDay ? "all day" : "\(formatTime(event.start))–\(formatTime(event.end))"
                let loc = event.location.map { " · \($0)" } ?? ""
                lines.append("- \(time) — \(event.title)\(loc)")
            }
            lines.append("")
        }

        if !inputs.completedTodosToday.isEmpty {
            lines.append("# Todos completed today")
            for todo in inputs.completedTodosToday {
                lines.append("- \(todo.title)")
            }
            lines.append("")
        }

        if !inputs.memoryTurns.isEmpty {
            lines.append("# Today's chat turns (chronological; some middle turns may be omitted to fit context)")
            for turn in inputs.memoryTurns {
                let role = turn.role == .user ? "User" : "Assistant"
                let stamp = formatTime(turn.createdAt)
                lines.append("[\(stamp)] \(role): \(truncate(turn.content, max: 280))")
            }
            lines.append("")
        }

        lines.append("Generate the .today compact memory now per the system rules.")
        return lines.joined(separator: "\n")
    }

    static func recentUserMessage(_ inputs: RecentInputs) -> String {
        var lines: [String] = []
        lines.append("Today is \(formatDateLong(inputs.now)). Generating .recent compact memory covering the past 30 days.")
        lines.append("")

        if let overall = inputs.previousOverallBody, !overall.isEmpty {
            lines.append("# Active .overall summary (background — do NOT repeat its content; reference it for what's already known long-term)")
            lines.append(overall)
            lines.append("")
        }

        if let prev = inputs.previousRecentBody, !prev.isEmpty {
            lines.append("# Previous .recent summary (regenerate, don't restart from scratch)")
            lines.append(prev)
            lines.append("")
        }

        if !inputs.facts.isEmpty {
            lines.append("# Recent semantic facts (last 30 days, non-private, non-superseded)")
            for fact in inputs.facts {
                let confirmed = fact.userConfirmed ? "[confirmed]" : "[auto]"
                let stamp = formatDateShort(fact.createdAt)
                let tags = fact.tags.isEmpty ? "" : " [\(fact.tags.joined(separator: ","))]"
                lines.append("- \(stamp) \(confirmed)\(tags) \(fact.body)")
            }
            lines.append("")
        }

        lines.append("Generate the .recent compact memory now per the system rules.")
        return lines.joined(separator: "\n")
    }

    static func overallUserMessage(_ inputs: OverallInputs) -> String {
        var lines: [String] = []
        lines.append("Today is \(formatDateLong(inputs.now)). Generating .overall compact memory — durable identity and lifetime patterns.")
        lines.append("")

        if let prev = inputs.previousOverallBody, !prev.isEmpty {
            lines.append("# Previous .overall summary (regenerate, evolving slowly; preserve durable content)")
            lines.append(prev)
            lines.append("")
        }

        if let recent = inputs.previousRecentBody, !recent.isEmpty {
            lines.append("# Active .recent summary (handoff context — promote anything from here that has become durable)")
            lines.append(recent)
            lines.append("")
        }

        if !inputs.facts.isEmpty {
            lines.append("# User-confirmed semantic facts (non-private, non-superseded, all-time)")
            for fact in inputs.facts {
                let stamp = formatDateShort(fact.createdAt)
                let tags = fact.tags.isEmpty ? "" : " [\(fact.tags.joined(separator: ","))]"
                lines.append("- \(stamp)\(tags) \(fact.body)")
            }
            lines.append("")
        }

        lines.append("Generate the .overall compact memory now per the system rules.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Formatters

    private static func formatDateLong(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).year().month(.wide).day())
    }

    private static func formatDateShort(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.abbreviated).day())
    }

    private static func formatTime(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    private static func truncate(_ s: String, max: Int) -> String {
        s.count <= max ? s : (s.prefix(max - 1) + "…")
    }
}
