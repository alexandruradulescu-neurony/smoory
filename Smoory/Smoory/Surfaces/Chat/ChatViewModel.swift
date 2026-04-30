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

    private let systemPrompt = """
You are Smoory, a personal AI assistant for the user. You're running on the user's Mac.

You have access to:
- The user's calendar via get_calendar_window
- The user's active goals via get_active_goals
- The user's open todos via get_open_todos
- The user's memory of past conversations and learned facts via retrieve_memory
- create_todo to propose adding a new todo (the user sees a confirmation card)
- complete_todo, update_todo, defer_todo, delete_todo to manage existing todos (each surfaces a confirmation card)
- create_subtask to add a subtask under an existing parent todo
- write_memory_fact to silently record high-confidence facts the user states (confidence >= 0.85)
- postpone_scheduled_action to push a Smoory-scheduled prompt (day review, reminder) to a later time when the user says things like "remind me at 9 instead", "push it back two hours"
- skip_scheduled_action to skip a single occurrence of a recurring schedule when the user says "skip the day review tonight" — recurring future occurrences are unaffected

Use create_todo ONLY when the user explicitly asks for a discrete action item — "add a todo", "remind me to X", "I need to call Y tomorrow". Do NOT infer todos from goals, aspirations, or general statements of intent ("I want to learn Italian" is a goal, not a todo). A separate structuring layer handles goals, projects, people, infrastructure, availability, and tone observations from your conversation; you should not duplicate its work.

When the user references a todo by description ("the dentist one", "my high-priority Apollo todo"), call get_open_todos first to find the matching id, then call the action tool with that todo_id. Don't ask the user for the UUID. Subtasks are nested inside their parent in the get_open_todos response — use them when the user references a subtask.

Use write_memory_fact ONLY for explicit, durable factual statements the user makes about themselves or their world — "I'm vegetarian", "my partner's name is Maria", "I live in Bucharest". Do NOT use it for goals, aspirations, project plans, or anything that sounds like ambient capture; the structuring layer surfaces those as candidates for the user to confirm. Confidence must be >= 0.85.

The compact summaries below are always-on. For specific past facts, names, or events, use retrieve_memory with a focused query.

Be conversational, concise, and honest about what you don't know. If memory retrieval returns nothing relevant, say so.
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
        scheduledActionService: ScheduledActionService? = nil
    ) {
        self.modelContainer = modelContainer
        self.hema = hema
        self.chatSessionID = chatSessionID
        // CalendarService is @MainActor — construct inside this @MainActor init so the
        // default-arg evaluation doesn't cross actor boundaries.
        let resolvedCalendar = calendarService ?? CalendarService()
        let services = ToolServices(
            calendarService: resolvedCalendar,
            modelContainer: modelContainer,
            hema: hema,
            scheduledActionService: scheduledActionService
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
        let createdTodos: [String] = toolExchanges
            .filter { $0.toolName == "create_todo" }
            .compactMap { Self.extractStringField("title", fromJSON: $0.parametersJSON) }
        let writtenFacts: [String] = toolExchanges
            .filter { $0.toolName == "write_memory_fact" }
            .compactMap { Self.extractStringField("body", fromJSON: $0.parametersJSON) }

        let alreadyHandled = StructuringPrompt.AlreadyHandled(
            createdTodoTitles: createdTodos,
            writtenFactBodies: writtenFacts
        )

        await structuringService.extract(
            userMessage: userMessage,
            recentTurns: recentTurns,
            chatSessionID: chatSessionID,
            sourceTurnID: nil,
            alreadyHandled: alreadyHandled
        )
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
