import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class ChatViewModel {
    struct Turn: Identifiable, Hashable {
        enum Speaker: Sendable, Hashable { case user, assistant, errorBubble }
        let id: UUID
        let speaker: Speaker
        let text: String
        let usedToolNames: [String]?
    }

    enum TurnState: Sendable, Hashable {
        case idle
        case sending
    }

    private(set) var turns: [Turn] = []
    private(set) var state: TurnState = .idle
    var draft: String = ""
    private(set) var pendingActions: [String: PendingAction] = [:]
    let modelContainer: ModelContainer

    /// True while the user is in the first-run onboarding conversation. When true, the
    /// system prompt is augmented to nudge Claude into onboarding behavior (no tool calls,
    /// guided topic walk).
    private(set) var onboardingMode: Bool = false

    private let orchestrator: Orchestrator
    let hema: HemaService
    private let chatSessionID: UUID
    private let services: ToolServices
    private let structuringService: StructuringService
    private var pendingContinuations: [String: CheckedContinuation<ToolOutput, Never>] = [:]
    /// 4.4 — batched fact extractor wired in from app level. Used by the idle
    /// timer below. Optional so non-app callers (tests, previews) can construct
    /// a ChatViewModel without wiring extraction.
    private let batchedFactExtractor: BatchedFactExtractor?
    /// 4.4 — high-water mark used to avoid re-extracting the same chat turns.
    /// In-memory only; app restart resets it (per milestone-4.4 design choice).
    /// On restart, the app-launch trigger pulls the last 24h of turns through
    /// the salience gate so any turns before quit get a chance.
    private var lastExtractionAt: Date?
    /// 4.4 — fires idle-pause extraction after 15 min of chat silence. Reset
    /// on every successful send() completion.
    private var idleTimer: Timer?

    private let systemPrompt = """
You are Smoory, a personal AI assistant for the user. You're running on the user's Mac.

# Tools

You have access to:
- The user's calendar via get_calendar_window
- The user's active goals via get_active_goals
- The user's open todos via get_open_todos
- The user's memory of past conversations and learned facts via retrieve_memory
- create_todo to propose adding a new todo (the user sees a confirmation card). If the user mentions a date or deadline ("by Friday", "tomorrow", "end of month"), pass it as `due_date` (ISO 8601). Don't drop the date silently.
- complete_todo, update_todo, defer_todo, delete_todo to manage existing todos (each surfaces a confirmation card)
- create_subtask to add a subtask under an existing parent todo
- write_memory_fact to silently record high-confidence facts the user states (confidence >= 0.85)
- postpone_scheduled_action to push a Smoory-scheduled prompt (day review, reminder) to a later time when the user says things like "remind me at 9 instead", "push it back two hours"
- skip_scheduled_action to skip a single occurrence of a recurring schedule when the user says "skip the day review tonight" — recurring future occurrences are unaffected
- create_scheduled_action to set a reminder. Use when the user asks to be reminded of something at a specific time ("remind me tomorrow at 2pm to call the dentist", "in 30 minutes tell me to take the laundry out"). Pass content + scheduled_for. Prefer ISO 8601 for scheduled_for; natural-language phrases ("tomorrow", "tonight", "this afternoon", "in N minutes/hours/days", "today/tomorrow at HH:MM[am|pm]", "30 minutes before my dentist") are also accepted. The user sees a confirmation card with the resolved time.
- get_my_scheduled_actions to list the user's pending reminders. Use when the user asks "what reminders do I have?", "what's coming up?", or similar. Pass include_system=true only if they explicitly ask about system items (day reviews, etc.).
- get_lists, get_list_items to read the user's curated lists (reading list, packing list, groceries, gift ideas, etc.)
- create_list to create a new list — pass title and kind ("checklist" for items with completion state, "notes" for plain bullets)
- add_to_list to add an item — accepts list_id or list_name
- complete_list_item to mark a checklist item done (or undo with completed=false)
- remove_from_list to delete one item (confirmation card)
- delete_list to archive a whole list (confirmation card; items preserved)
- rename_list to change a list's title — accepts list_id or list_name plus new_title
- reorder_list_items to set the display order of items — pass the FULL ordered array of every item id in the list (call get_list_items first to see the current ids)

The orchestrator runs tool calls issued in the same turn in parallel. When you need data from two or more tools to answer well, request them together — don't chain them across turns.

Lists ≠ todos. Use a list when the user is curating a collection ("add 'Hyperion' to my reading list", "make a packing list for Lisbon"). Use create_todo when the user is committing to do a tactical thing. If unclear, ask. When the user says "make a list of X", create the list first, then add items in subsequent calls of add_to_list. complete_list_item only works on checklist-kind lists; calling it on a notes-kind list returns an error.

# Tool selection

Use create_todo ONLY when the user explicitly asks for a persistent action item without a specific fire time — "add a todo to call the dentist", "I need to finish the deck", "put 'review pricing' on my list". Do NOT infer todos from goals, aspirations, or general statements of intent ("I want to learn Italian" is a goal, not a todo). A separate structuring layer handles goals, projects, people, infrastructure, availability, and tone observations from your conversation; you should not duplicate its work.

CRITICAL — todo vs. reminder disambiguation:
- "remind me at <time> to X" / "remind me <N> minutes before <event>" / "remind me tomorrow at 2pm" → create_scheduled_action ONLY. Do NOT also create_todo for the same intent.
- "remind me to X" with NO time → create_todo (the user wants a list item, not a notification at a specific moment).
- "I want to <do thing> on <day> at <time>, remind me <before>" → ONE create_scheduled_action with content describing the thing and scheduled_for resolved against the offset. Do NOT also fire create_todo for the underlying meeting/event — the reminder covers it.
- When in doubt and the user gave a specific clock time, default to create_scheduled_action and skip create_todo.

Fire at most ONE of {create_todo, create_scheduled_action} per intent. If both seem to fit, pick the one matching the user's primary phrasing — usually the verb they used.

When the user references a todo by description ("the dentist one", "my high-priority Apollo todo"), call get_open_todos first to find the matching id, then call the action tool with that todo_id. Don't ask the user for the UUID. Subtasks are nested inside their parent in the get_open_todos response — use them when the user references a subtask.

Use write_memory_fact ONLY for explicit, durable factual statements the user makes about themselves or their world — "I'm vegetarian", "my partner's name is Maria", "I live in Bucharest". Do NOT use it for goals, aspirations, project plans, or anything that sounds like ambient capture; the structuring layer surfaces those as candidates for the user to confirm. Confidence must be >= 0.85.

# Memory lifecycle

You CANNOT delete or supersede facts directly. There is no delete_fact or supersede_fact tool. The user resolves contradictions via the Feed — when contradiction detection flags two conflicting facts, a supersession candidate appears in the Feed and the user confirms or marks both true.

If retrieve_memory returns facts that contradict each other, you may mention the contradiction neutrally — e.g. "memory has both 'you're vegetarian' and 'you had a steak last week'; resolve in the Feed if you want one to win". Do NOT claim to have deleted, superseded, replaced, or removed a fact. Do NOT offer to delete a fact for the user. The structuring layer and the contradiction detector do that on their own; you stay descriptive.

# Retrieval discipline

When the user asks about commitments, schedule, plans, or anything time-bound, your default is to check BOTH sources of truth:

1. The calendar — formal events with explicit times — via get_calendar_window.
2. Memory — recurring meetings, informal commitments, things the user has mentioned but not calendared — via retrieve_memory.

The calendar is incomplete. Recurring informal meetings, founder syncs, regular calls, and many of the user's actual commitments live only in memory. Calendar-only answers will miss them.

Rule: For "what am I doing today / tonight / tomorrow / Monday / this weekend / after 5pm", "any plans for X", "what's on later", "should I be somewhere right now" — call get_calendar_window AND retrieve_memory in the same turn. The orchestrator runs them in parallel. Combine the results before answering.

Do NOT say "nothing scheduled", "your calendar is clear", "I don't have that pinned down", or "your evening is free" until BOTH tools have been called. If the user pushes back ("but we discussed it earlier") that means you should have already called retrieve_memory — call it now and answer from the combined result.

When retrieve_memory returns nothing relevant, say so plainly. Don't paper over an empty result.

retrieve_memory queries should be focused: include the time window (today, tonight, this week) and the activity type (meetings, calls, plans) so the vector search matches the right turns and facts.

Example queries:
- For "what am I doing tonight?": query "tonight evening commitments" or specific terms the user uses for their recurring activities (e.g., "founder meeting Monday").
- For "any plans for the weekend?": query "weekend plans Saturday Sunday".
- For "what about my Apollo project?": query "Apollo migration".

Bad query: "schedule" (too broad).
Bad query: "user activities" (meta-language, not what's in memory).

# Time reasoning

The Orchestrator appends a <current_datetime> block to your context on every turn. It looks like this at runtime:

<current_datetime>
Today is Monday, May 4, 2026. Local time is 18:16 EEST (Europe/Bucharest). Resolve relative dates ("today", "tomorrow", "next Monday") and relative times ("in an hour", "tonight") against this.
</current_datetime>

Use it. Reason about the current moment before answering anything time-bound.

Specific rules:
- "After 5pm" means after 17:00 — INCLUDING right now if the current time is past 17:00. If it's currently 18:16 and the user asks "what am I doing after 5pm", they're asking about the present and the rest of the evening, not the future.
- "Today" includes the rest of today from now. A 17:00 thing when the current time is 18:16 has already started or wrapped — not "later today".
- "Tonight" = evening hours of today.
- "Tomorrow" = the next calendar day.
- "Next week" = the upcoming Monday–Sunday window.
- "In 30 minutes" / "this afternoon" / "by EOD" — compute the actual target time from the current time and answer concretely.

Don't tell the user "nothing scheduled after 5pm" if it's currently 19:00 and they had a 17:00 meeting — that meeting was between "after 5pm" and "now". Acknowledge it: "You had your founder sync at 17:00 — should be wrapping up around now."

When you cite a time, prefer concrete forms ("at 17:00", "in 90 minutes", "around 19:30") over vague ones ("later today", "in a bit").

# Voice

The user wants a thoughtful friend who knows their context, gets to the point, and trusts them to drive the conversation. Not a chatbot, not a coach, not a therapist.

DO NOT:
- Use emojis. Not 👋, not 🎉, not country flags, not smileys. Zero emojis in normal conversation. Mirror the user's energy if they use them — but default is none.
- Use exclamation points except in rare moments of genuine enthusiasm tied to a real event the user shared. Default sentence terminator is a period.
- End every message with a question or offer. Many messages should end declaratively. Let the user drive.
- Use performative warmth: "always happy to chat", "great question", "thanks for sharing", "hope this helps", "let me know if you need anything else", "good to confirm".
- Open with "Hey!", "Hi there!", or similar greetings unless the user just greeted you first.
- Sycophant ("brilliant question", "love that you're thinking about this") or moralize.
- Narrate note-taking. Smoory writes facts silently or not at all — do NOT say "I'll make a note of that", "noted", "I'll remember that for next time", or any phrasing that performs the act of saving.

DO:
- Be brief. Most replies are 1–3 sentences. Multi-paragraph answers are reserved for genuine depth.
- Be direct. State the answer; skip preamble.
- Have opinions when asked, and own them.
- Acknowledge uncertainty when it exists. "I don't know" is a valid answer. So is "memory has nothing on that".
- Let silence happen. Some replies end without a follow-up. The user knows how to ask for more.

Voice examples:

User: "hello"
RIGHT: "Hey. What's up?"
WRONG: "Hey! 👋 How's your Monday going?"

User: "where am I now?"
RIGHT: "Bucharest, based on your timezone — you've told me that's home base since you moved from Moreni."
WRONG: "Right — you're in **Bucharest, Romania**! 🏙️ Not sure where exactly though — home, office, or out and about?"

User: "fine, what about you?"
RIGHT: "Doing what I do. What's on your mind?"
WRONG: "I'm doing great, thanks for asking! Always happy to chat. Anything on your mind — tasks, reminders, or just checking in?"

User: "thanks"
RIGHT: "Anytime."
WRONG: "Anytime! Let me know if you need anything else 😊"

User: "yes that's right"
RIGHT: "Got it."
WRONG: "Good to confirm! I'll make a note of that for future."
"""

    private let onboardingAddendum = """

ONBOARDING MODE — IMPORTANT:
You are walking the user through first-run onboarding. Walk through these topics conversationally, one at a time, without rushing:

1. Roles — facets of life ("employed at X", "running a side business", "freelance")
2. Goals — what they're working toward (read more, ship X, exercise more)
3. Projects — concrete efforts under goals
4. Key people — partner, family, close colleagues, frequent collaborators
5. Infrastructure — services and tools they rely on (email, calendar, code host)
6. Working hours — when they're focused vs. off
7. Communication preferences — how they like Smoory to talk

Bridge naturally between topics. Don't ask all at once.

When you paraphrase to confirm understanding, use questions or short acknowledgments rather than restatements. Say "Got it." or "Makes sense — what about...?" instead of "So you're working on Apollo as a side project." This prevents your paraphrase from being re-extracted as a duplicate candidate by the structuring layer.

Do NOT call create_todo or write_memory_fact during onboarding. The structuring layer will surface candidates from what the user says, and the user will review them in the Feed at the end.

When you sense the user has covered the basics, or the user signals they're done, say something like: "I think we have a good starting picture. Take a look at the Feed when you're ready and confirm the items I picked up."
"""

    init(
        modelContainer: ModelContainer,
        hema: HemaService,
        chatSessionID: UUID,
        client: LLMClient = RoutingLLMClient(),
        calendarService: CalendarService? = nil,
        scheduledActionService: ScheduledActionService? = nil,
        batchedFactExtractor: BatchedFactExtractor? = nil,
        factRestructurer: FactRestructurer? = nil
    ) {
        self.modelContainer = modelContainer
        self.hema = hema
        self.chatSessionID = chatSessionID
        self.batchedFactExtractor = batchedFactExtractor
        // CalendarService is @MainActor — construct inside this @MainActor init so the
        // default-arg evaluation doesn't cross actor boundaries.
        let resolvedCalendar = calendarService ?? CalendarService()
        let services = ToolServices(
            calendarService: resolvedCalendar,
            modelContainer: modelContainer,
            hema: hema,
            scheduledActionService: scheduledActionService,
            batchedFactExtractor: batchedFactExtractor,
            factRestructurer: factRestructurer
        )
        self.services = services
        self.orchestrator = Orchestrator(
            client: client,
            registry: ToolRegistry.allTools,
            services: services,
            chatSessionID: chatSessionID
        )
        self.structuringService = StructuringService(
            client: client,
            modelContainer: modelContainer
        )
        self.orchestrator.delegate = self
    }

    func send() async {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, state != .sending else { return }

        // Slash command intercept: explicit onboarding end.
        if trimmed.lowercased() == "/end onboarding" || trimmed.lowercased() == "/finish onboarding" {
            draft = ""
            endOnboarding()
            return
        }

        // Slash command intercept: re-enter onboarding for users who skipped or
        // want a refresher.
        if trimmed.lowercased() == "/start onboarding" || trimmed.lowercased() == "/restart onboarding" {
            draft = ""
            startOnboarding()
            return
        }

        let userTurn = Turn(id: UUID(), speaker: .user, text: trimmed, usedToolNames: nil)
        turns.append(userTurn)
        draft = ""
        state = .sending

        // Pre-create assistant turn placeholder so cards have a parent ID.
        let assistantTurnID = UUID()
        let placeholder = Turn(id: assistantTurnID, speaker: .assistant, text: "", usedToolNames: nil)
        turns.append(placeholder)

        let history: [LLMMessage] = turns
            .filter { $0.speaker != .errorBubble && $0.id != userTurn.id && $0.id != assistantTurnID }
            .map { turn in
                let role: LLMMessage.Role = (turn.speaker == .user) ? .user : .assistant
                return LLMMessage(role: role, text: turn.text)
            }

        do {
            let result = try await orchestrator.send(
                systemPrompt: effectiveSystemPrompt,
                history: history,
                userMessage: trimmed,
                modelTier: .balanced,
                assistantTurnID: assistantTurnID
            )

            switch result.stoppedReason {
            case .naturalEnd, .maxRoundsReached, .userCancelled:
                let usedNames = Self.deduplicate(result.toolExchanges.map(\.toolName))
                let displayText = result.finalText.isEmpty ? "" : result.finalText
                replaceTurn(id: assistantTurnID, with: Turn(
                    id: assistantTurnID,
                    speaker: .assistant,
                    text: displayText,
                    usedToolNames: usedNames.isEmpty ? nil : usedNames
                ))

                let shouldPersist: Bool
                switch result.stoppedReason {
                case .naturalEnd, .maxRoundsReached: shouldPersist = true
                default: shouldPersist = false
                }
                if shouldPersist {
                    let userMessageToPersist = trimmed
                    let assistantTextToPersist = result.finalText
                    let exchangesSnapshot = result.toolExchanges
                    let recentTurnsSnapshot = Self.recentTurnTexts(turns: turns, excluding: [userTurn.id, assistantTurnID])
                    Task {
                        await self.persistTurns(
                            userMessage: userMessageToPersist,
                            assistantReply: assistantTextToPersist
                        )
                    }
                    Task {
                        await self.runStructuringExtraction(
                            userMessage: userMessageToPersist,
                            recentTurns: recentTurnsSnapshot,
                            toolExchanges: exchangesSnapshot
                        )
                    }
                    // 4.4 — reset the 15-min idle timer on successful turn
                    // completion. If the timer fires before the next turn, run
                    // batched fact extraction over hema turns since the last
                    // extraction marker.
                    resetIdleTimer()
                }
            case .clientError(let error):
                removePlaceholder(id: assistantTurnID)
                turns.append(Turn(
                    id: UUID(),
                    speaker: .errorBubble,
                    text: Self.friendlyMessage(for: error),
                    usedToolNames: nil
                ))
            }
        } catch {
            removePlaceholder(id: assistantTurnID)
            turns.append(Turn(
                id: UUID(),
                speaker: .errorBubble,
                text: Self.friendlyMessage(for: error),
                usedToolNames: nil
            ))
        }
        state = .idle
    }

    // MARK: - Onboarding

    private var effectiveSystemPrompt: String {
        onboardingMode ? systemPrompt + onboardingAddendum : systemPrompt
    }

    /// Called by the first-launch welcome sheet's Start button.
    /// Posts a synthetic assistant greeting if the conversation is empty so the user
    /// doesn't have to type first.
    func startOnboarding() {
        onboardingMode = true
        if turns.isEmpty {
            let greeting = Turn(
                id: UUID(),
                speaker: .assistant,
                text: "Hey 👋 Welcome to Smoory. Let's spend a little time getting me up to speed on you — your roles, goals, projects, key people, and the tools you use. We'll go through one topic at a time, no rush. To start: what do you spend most of your time on these days?",
                usedToolNames: nil
            )
            turns.append(greeting)
        }
    }

    /// Called by the slash command, the onboarding banner's Finish button, or the welcome
    /// sheet's Skip button (the latter without ever entering inProgress).
    func endOnboarding() {
        onboardingMode = false
        OnboardingStateStore.set(.completed)
    }

    // MARK: - PendingAction transitions (called from PendingActionCard)

    func enterEditMode(toolUseId: String) {
        guard var action = pendingActions[toolUseId] else { return }
        action.state = .editing
        pendingActions[toolUseId] = action
    }

    func cancelEdit(toolUseId: String) {
        guard var action = pendingActions[toolUseId] else { return }
        action.state = .pending
        pendingActions[toolUseId] = action
    }

    func commitEdit(toolUseId: String, newParametersJSON: String) {
        guard var action = pendingActions[toolUseId] else { return }
        action.editedParametersJSON = newParametersJSON
        action.state = .pending
        pendingActions[toolUseId] = action
    }

    func confirmAction(toolUseId: String) async {
        guard var action = pendingActions[toolUseId] else { return }
        action.state = .executing
        pendingActions[toolUseId] = action

        guard let toolType = ToolRegistry.tool(named: action.toolName) else {
            resolveContinuation(toolUseId: toolUseId, output: ToolOutput(
                toolUseId: toolUseId,
                content: "Unknown tool",
                isError: true
            ))
            action.state = .failed(reason: "Unknown tool")
            pendingActions[toolUseId] = action
            return
        }

        let parameters = action.effectiveParametersJSON
        let context = ToolExecutionContext(
            toolUseId: toolUseId,
            chatSessionID: chatSessionID,
            services: services
        )

        do {
            let output = try await toolType.execute(parametersJSON: parameters, context: context)
            let summary = Self.confirmedSummary(toolName: action.toolName,
                                                  parametersJSON: parameters,
                                                  modelContainer: modelContainer)
            action.state = .confirmed(summary: summary)
            pendingActions[toolUseId] = action
            resolveContinuation(toolUseId: toolUseId, output: output)
        } catch {
            let reason = "Couldn't \(action.toolName) — \(error.localizedDescription)"
            action.state = .failed(reason: reason)
            pendingActions[toolUseId] = action
            resolveContinuation(toolUseId: toolUseId, output: ToolOutput(
                toolUseId: toolUseId,
                content: "Tool error: \(error.localizedDescription)",
                isError: true
            ))
        }
    }

    func declineAction(toolUseId: String) {
        guard var action = pendingActions[toolUseId] else { return }
        let primary = ToolRegistry.tool(named: action.toolName)?
            .renderSummary(parametersJSON: action.effectiveParametersJSON, modelContainer: modelContainer)?
            .primary
        let title = ToolRegistry.tool(named: action.toolName)?
            .renderSummary(parametersJSON: action.effectiveParametersJSON, modelContainer: modelContainer)?
            .title ?? action.toolName
        let summary = primary.map { "\(title) (\($0))" } ?? title
        action.state = .declined(summary: summary)
        pendingActions[toolUseId] = action

        let json = #"{"status":"declined","note":"User declined this action; do not propose it again unless the user changes their mind"}"#
        resolveContinuation(toolUseId: toolUseId, output: ToolOutput(
            toolUseId: toolUseId,
            content: json,
            isError: false
        ))
    }

    // MARK: - Internals

    private func resolveContinuation(toolUseId: String, output: ToolOutput) {
        if let continuation = pendingContinuations.removeValue(forKey: toolUseId) {
            continuation.resume(returning: output)
        }
    }

    private func replaceTurn(id: UUID, with newTurn: Turn) {
        if let idx = turns.firstIndex(where: { $0.id == id }) {
            turns[idx] = newTurn
        }
    }

    private func removePlaceholder(id: UUID) {
        turns.removeAll { $0.id == id && $0.text.isEmpty }
    }

    private func persistTurns(userMessage: String, assistantReply: String) async {
        do {
            try await hema.writeTurn(MemoryTurn(
                id: UUID(),
                createdAt: Date(),
                chatSessionID: chatSessionID,
                role: .user,
                content: userMessage,
                vector: nil
            ))
            if !assistantReply.isEmpty {
                try await hema.writeTurn(MemoryTurn(
                    id: UUID(),
                    createdAt: Date(),
                    chatSessionID: chatSessionID,
                    role: .assistant,
                    content: assistantReply,
                    vector: nil
                ))
            }
        } catch {
            print("[chat] hema write failed: \(error)")
        }
    }

    // MARK: - Structuring layer trigger

    /// Builds the AlreadyHandled hint set from this turn's tool exchanges so the structuring
    /// prompt won't re-propose what Claude already wrote.
    private func runStructuringExtraction(
        userMessage: String,
        recentTurns: [String],
        toolExchanges: [ToolExchange]
    ) async {
        // Only count successful exchanges so cancelling a confirmation card doesn't also
        // suppress the structuring layer's candidate — the candidate is the safety net.
        let successfulTodoExchanges = toolExchanges.filter {
            $0.toolName == "create_todo" && !$0.result.isError
        }
        let successfulFactExchanges = toolExchanges.filter {
            $0.toolName == "write_memory_fact" && !$0.result.isError
        }
        let createdTodos: [String] = successfulTodoExchanges
            .compactMap { Self.extractStringField("title", fromJSON: $0.parametersJSON) }
        let writtenFacts: [String] = successfulFactExchanges
            .compactMap { Self.extractStringField("body", fromJSON: $0.parametersJSON) }
        let anyTodoToolFired = !successfulTodoExchanges.isEmpty
        let anyFactToolFired = !successfulFactExchanges.isEmpty

        let alreadyHandled = StructuringPrompt.AlreadyHandled(
            createdTodoTitles: createdTodos,
            writtenFactBodies: writtenFacts,
            anyTodoToolFired: anyTodoToolFired,
            anyFactToolFired: anyFactToolFired
        )

        await structuringService.extract(
            userMessage: userMessage,
            recentTurns: recentTurns,
            chatSessionID: chatSessionID,
            sourceTurnID: nil,
            alreadyHandled: alreadyHandled
        )
    }

    // MARK: - Idle-pause batched extraction (4.4)

    /// Schedules a one-shot 15-min idle timer. If it fires (i.e., no further
    /// chat turns in the next 15 minutes), runs batched fact extraction over
    /// hema turns recorded since the last extraction marker. Cancelled and
    /// rescheduled on every successful send().
    private func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fireIdleExtraction()
            }
        }
    }

    private func fireIdleExtraction() async {
        guard let extractor = batchedFactExtractor else { return }
        // Pull turns from hema since the last extraction marker. First-time
        // fall back is "since one hour ago" so the salience gate has a window
        // to reason over.
        let since = lastExtractionAt ?? Date().addingTimeInterval(-3600)
        let turns = (try? await hema.readAllTurns(limit: 500, since: since)) ?? []
        // readAllTurns returns DESC; extractor wants chronological for arc
        // sensitivity in the salience and extraction prompts.
        let chronological = Array(turns.reversed())
        await extractor.extract(turns: chronological, trigger: .idlePause)
        // Update marker regardless of salience verdict — we do not want to
        // re-process the same window on the next idle fire.
        lastExtractionAt = Date()
    }

    private static func recentTurnTexts(turns: [Turn], excluding excludedIDs: [UUID]) -> [String] {
        let kept = turns
            .filter { $0.speaker != .errorBubble && !excludedIDs.contains($0.id) }
            .suffix(6)
        return kept.map { turn in
            let prefix = turn.speaker == .user ? "User:" : "Assistant:"
            return "\(prefix) \(turn.text)"
        }
    }

    private static func extractStringField(_ field: String, fromJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj[field] as? String
    }

    private static func confirmedSummary(toolName: String, parametersJSON: String, modelContainer: ModelContainer) -> String {
        let summary = ToolRegistry.tool(named: toolName)?.renderSummary(parametersJSON: parametersJSON, modelContainer: modelContainer)
        let verb: String
        switch toolName {
        case "create_todo": verb = "Created todo"
        case "complete_todo": verb = "Completed"
        case "update_todo": verb = "Updated"
        case "defer_todo": verb = "Deferred"
        case "delete_todo": verb = "Archived"
        case "create_subtask": verb = "Added subtask"
        default: verb = "Done"
        }
        return summary.map { "\(verb): \($0.primary)" } ?? verb
    }

    private static func deduplicate(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private static func friendlyMessage(for error: Error) -> String {
        if let llmError = error as? LLMClientError {
            let provider = AIProviderStore.current().displayName
            switch llmError {
            case .missingAPIKey:
                return "No \(provider) API key configured. Add one in Settings."
            case .unauthorized:
                return "The \(provider) API key in Settings looks invalid. Replace it in Settings."
            case .rateLimited:
                return "\(provider) is rate-limiting requests. Try again in a moment."
            case .server(let status, _):
                return "\(provider) returned a server error (\(status)). Try again shortly."
            case .network:
                return "Network problem. Check your connection and try again."
            case .invalidResponse, .decoding:
                return "Got an unexpected response from \(provider). This is likely a Smoory bug."
            case .unknown:
                return "Something went wrong. Try again."
            }
        }
        return error.localizedDescription
    }
}

// MARK: - OrchestratorDelegate

extension ChatViewModel: OrchestratorDelegate {
    func handlePendingAction(
        toolName: String,
        parametersJSON: String,
        toolUseId: String,
        confirmationTier: ConfirmationTier,
        assistantTurnID: UUID
    ) async -> ToolOutput {
        let action = PendingAction(
            id: toolUseId,
            toolName: toolName,
            parametersJSON: parametersJSON,
            editedParametersJSON: nil,
            confirmationTier: confirmationTier,
            proposedAt: Date(),
            state: .pending,
            assistantTurnID: assistantTurnID
        )
        pendingActions[toolUseId] = action

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingContinuations[toolUseId] = continuation
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let continuation = self.pendingContinuations.removeValue(forKey: toolUseId) {
                    continuation.resume(returning: ToolOutput(
                        toolUseId: toolUseId,
                        content: OrchestratorContract.cancelledMarkerJSON,
                        isError: true
                    ))
                }
            }
        }
    }
}
