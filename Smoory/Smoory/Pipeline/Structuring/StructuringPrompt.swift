import Foundation

/// Prompt assembly + JSON parsing for the structuring layer.
enum StructuringPrompt {
    static let systemPrompt = """
    You are the structuring layer for Smoory. Read the user's message and extract any \
    STRUCTURABLE information — anything that should become a record in Smoory's database.

    Be ACTIVE about extraction. If the user mentions a goal, a person, a fact about themselves, \
    a future action item, an availability change, or a preference — capture it. The user is \
    telling Smoory things to remember; your job is to spot the things worth remembering.

    Categories:
    - "goal": a long-lived intention. "I want to read more"; "I want to ship X by Y date".
    - "project": a concrete bundled effort. "I'm starting a new project on X".
    - "todo": a discrete action item. "I need to call Maria tomorrow".
    - "person": a person not yet in Smoory. "Met Pedro at the conference; he works at Anthropic".
    - "infrastructure": a service/tool/account. "My business email is on Fastmail".
    - "availability": time-bounded user availability. "I'll be off Tuesday"; "I have a deep block tomorrow".
    - "tone_observation": preferences about communication. "I like terse replies".

    Do NOT emit "fact" candidates. Durable semantic facts about the user are extracted by a separate batched pass triggered at idle pauses, day-review time, and app backgrounding. Per-turn extraction commits half-formed ideas; the batched pass sees the full arc.

    Output strict JSON. No prose, no fences, no commentary. Schema:
    {"candidates": [
      {"type": "<category>", "content": "<record-ready third-person statement>",
       "title": "<short label, REQUIRED for goal/project; omit for other types>",
       "confidence": <0.0-1.0>, "expires_at": "<ISO date or null>",
       "user_phrase": "<the literal words from the user>"}
    ]}

    Rules:
    - If nothing is structurable, return {"candidates": []}.
    - Do NOT propose duplicates of existing records or anything already handled this turn.
    - "content" is a record-ready third-person statement, not a quote.
    - "title" — REQUIRED for "goal" and "project". Short noun-phrase label (3-7 words),
      Title-Cased, no trailing period. Examples: "Read 50 Pages a Day", "Learn Latin",
      "Apollo Migration", "Half Marathon Training". DO NOT include time qualifiers
      ("by Q4", "in the next month") or third-person framing ("User wants to ..."). Goal/
      project entities use this as their displayed name; the "content" field becomes the
      goal's longer description.
    - "user_phrase" is the literal words from the user.

    Examples:

    User message: "I want to read 50 pages a day"
    Output: {"candidates": [{"type": "goal", "content": "User wants to read 50 pages per day", "title": "Read 50 Pages a Day", "confidence": 0.92, "expires_at": null, "user_phrase": "I want to read 50 pages a day"}]}

    User message: "ok thanks"
    Output: {"candidates": []}

    User message: "Met someone called Pedro at the conference, he works at Anthropic. Also I'm vegetarian btw."
    Output: {"candidates": [
      {"type": "person", "content": "Pedro works at Anthropic; user met him at a conference", "confidence": 0.88, "expires_at": null, "user_phrase": "Met someone called Pedro at the conference, he works at Anthropic"},
      {"type": "fact", "content": "User is vegetarian", "confidence": 0.95, "expires_at": null, "user_phrase": "I'm vegetarian btw"}
    ]}

    User message: "I'll be off next Tuesday and Wednesday"
    Output: {"candidates": [{"type": "availability", "content": "User is off Tuesday and Wednesday next week", "confidence": 0.9, "expires_at": "2026-05-13", "user_phrase": "I'll be off next Tuesday and Wednesday"}]}
    """

    struct Snapshot: Sendable {
        let roleNames: [String]
        let goalTitles: [String]
        let projectTitles: [String]
        let personNames: [String]
    }

    struct AlreadyHandled: Sendable {
        let createdTodoTitles: [String]
        let writtenFactBodies: [String]
        /// True when any `create_todo` tool fired in this turn — even if the LLM-supplied
        /// title doesn't match the structuring candidate's content/phrase. Defends against
        /// the dedup race where the assistant titles a todo "Call Maria" while the
        /// structuring LLM emits content "User needs to call Maria tomorrow" — neither
        /// string matches but they refer to the same intent.
        let anyTodoToolFired: Bool
        /// Symmetric guard for `write_memory_fact`. Drops all `.fact` candidates whose
        /// content/phrase doesn't exactly match a written fact body — same race, lower
        /// likelihood (fact bodies usually echo the user's words) but worth covering.
        let anyFactToolFired: Bool

        init(
            createdTodoTitles: [String],
            writtenFactBodies: [String],
            anyTodoToolFired: Bool = false,
            anyFactToolFired: Bool = false
        ) {
            self.createdTodoTitles = createdTodoTitles
            self.writtenFactBodies = writtenFactBodies
            self.anyTodoToolFired = anyTodoToolFired
            self.anyFactToolFired = anyFactToolFired
        }
    }

    static func assembleUserMessage(
        userMessage: String,
        recentTurns: [String],
        snapshot: Snapshot,
        alreadyHandled: AlreadyHandled
    ) -> String {
        let existingBlock = """
        Existing records (do NOT propose duplicates):
        - Roles: \(formatList(snapshot.roleNames))
        - Goals: \(formatList(snapshot.goalTitles))
        - Projects: \(formatList(snapshot.projectTitles))
        - Person names: \(formatList(snapshot.personNames))
        """

        let handledBlock = """
        Already handled in this turn (do NOT propose):
        - Todos already created: \(formatList(alreadyHandled.createdTodoTitles))
        - Facts already written: \(formatList(alreadyHandled.writtenFactBodies))
        """

        let recentBlock = recentTurns.isEmpty
            ? "(no prior turns)"
            : recentTurns.joined(separator: "\n")

        return """
        \(existingBlock)

        \(handledBlock)

        Recent context:
        \(recentBlock)

        User message:
        \(userMessage)
        """
    }

    private static func formatList(_ items: [String]) -> String {
        items.isEmpty ? "(none)" : items.map { "\"\($0)\"" }.joined(separator: ", ")
    }

    /// Best-effort JSON parsing. Returns empty array on any failure (logged by caller).
    static func parse(_ text: String) -> [ParsedCandidate]? {
        // Some models wrap output in fences despite instructions. Strip if present.
        let cleaned = stripFences(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["candidates"] as? [[String: Any]]
        else {
            return nil
        }
        return raw.compactMap(ParsedCandidate.init(from:))
    }

    private static func stripFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            // Drop first line up to newline (e.g. ```json) and trailing fence.
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

struct ParsedCandidate: Sendable {
    let type: CandidateType
    let content: String
    let title: String              // short label; required for goal/project, empty otherwise
    let confidence: Double
    let expiresAt: Date?
    let userPhrase: String

    init?(from dict: [String: Any]) {
        guard let typeStr = dict["type"] as? String,
              let type = CandidateType.fromJSON(typeStr),
              let content = dict["content"] as? String,
              !content.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }

        let confidence: Double = {
            if let d = dict["confidence"] as? Double { return d }
            if let i = dict["confidence"] as? Int { return Double(i) }
            return 0
        }()

        var parsedExpiry: Date?
        if let s = dict["expires_at"] as? String, !s.isEmpty {
            parsedExpiry = (try? Date(s, strategy: .iso8601))
                ?? (try? Date.ISO8601FormatStyle().year().month().day().parse(s))
        }

        self.type = type
        self.content = content
        self.title = (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.confidence = confidence
        self.expiresAt = parsedExpiry
        self.userPhrase = (dict["user_phrase"] as? String) ?? ""
    }
}
