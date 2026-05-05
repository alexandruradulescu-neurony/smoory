import Foundation
import Observation
import SwiftData

/// 4.10 — operational counterpart to `DayReviewViewModel`. Drives the end-of-day
/// shutdown session: loose-end cleanup, tomorrow prep, lights-out summary.
/// Uses `EndOfDayPrompts.systemPrompt` and `CompleteEndOfDayTool` instead of the
/// day-review pair; otherwise the conversation shape mirrors day review (turn loop,
/// orchestrator wiring, structuring extraction trigger, scheduled-action completion).
@Observable
@MainActor
final class EndOfDayViewModel {
    private(set) var turns: [ChatViewModel.Turn] = []
    private(set) var isSending: Bool = false
    /// Set to true when `complete_end_of_day` fires inside an LLM turn so the sheet
    /// can react via `.onChange` and dismiss.
    private(set) var shouldDismiss: Bool = false
    var draft: String = ""

    private let action: ScheduledAction
    /// Unique session ID per shutdown — keeps end-of-day hema turns visually distinct
    /// from main chat + day review in the Memory → Turns surface.
    private let chatSessionID: UUID = UUID()
    private let orchestrator: Orchestrator
    private let scheduledActionService: ScheduledActionService
    private let hema: HemaService
    private let structuringService: StructuringService
    private let firedAt: Date = Date()

    init(
        action: ScheduledAction,
        modelContainer: ModelContainer,
        hema: HemaService,
        scheduledActionService: ScheduledActionService,
        client: LLMClient = RoutingLLMClient(),
        calendarService: CalendarService? = nil,
        batchedFactExtractor: BatchedFactExtractor? = nil,
        factRestructurer: FactRestructurer? = nil
    ) {
        self.action = action
        self.hema = hema
        self.scheduledActionService = scheduledActionService

        let resolvedCalendar = calendarService ?? CalendarService()
        let services = ToolServices(
            calendarService: resolvedCalendar,
            modelContainer: modelContainer,
            hema: hema,
            scheduledActionService: scheduledActionService,
            batchedFactExtractor: batchedFactExtractor,
            factRestructurer: factRestructurer
        )
        self.orchestrator = Orchestrator(
            client: client,
            registry: ToolRegistry.allTools,
            services: services,
            chatSessionID: chatSessionID
        )
        self.structuringService = StructuringService(client: client, modelContainer: modelContainer)
    }

    func startIfNeeded() async {
        guard turns.isEmpty else { return }
        _ = try? scheduledActionService.markFiring(actionID: action.id)

        let opener = ChatViewModel.Turn(
            id: UUID(),
            speaker: .assistant,
            text: EndOfDayPrompts.randomOpener(),
            usedToolNames: nil
        )
        turns.append(opener)
        Task { try? await persistTurn(opener, role: .assistant) }
    }

    func send() async {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        isSending = true
        defer { isSending = false }

        let userTurn = ChatViewModel.Turn(id: UUID(), speaker: .user, text: trimmed, usedToolNames: nil)
        turns.append(userTurn)
        draft = ""
        Task { try? await persistTurn(userTurn, role: .user) }

        let assistantID = UUID()
        let placeholder = ChatViewModel.Turn(id: assistantID, speaker: .assistant, text: "", usedToolNames: nil)
        turns.append(placeholder)

        let history = turns.dropLast(2).map { turn -> LLMMessage in
            let role: LLMMessage.Role = (turn.speaker == .user) ? .user : .assistant
            return LLMMessage(role: role, text: turn.text)
        }

        do {
            let result = try await orchestrator.send(
                systemPrompt: EndOfDayPrompts.systemPrompt,
                history: Array(history),
                userMessage: trimmed,
                modelTier: .balanced,
                assistantTurnID: assistantID
            )

            let final = ChatViewModel.Turn(
                id: assistantID,
                speaker: .assistant,
                text: result.finalText.isEmpty ? "(empty response)" : result.finalText,
                usedToolNames: Self.extractToolNames(from: result.toolExchanges)
            )
            replace(id: assistantID, with: final)
            Task { try? await persistTurn(final, role: .assistant) }

            // complete_end_of_day signals natural end-of-conversation.
            if result.toolExchanges.contains(where: { $0.toolName == CompleteEndOfDayTool.name }) {
                await completeReview()
                shouldDismiss = true
                return
            }

            // Fire-and-forget structuring extraction so anything the user said during
            // the close surfaces as candidates in the Feed (parity with main chat).
            Task { [chatSessionID, sourceID = userTurn.id] in
                let recent = self.recentTurnTexts()
                await self.structuringService.extract(
                    userMessage: trimmed,
                    recentTurns: recent,
                    chatSessionID: chatSessionID,
                    sourceTurnID: sourceID,
                    alreadyHandled: StructuringPrompt.AlreadyHandled(
                        createdTodoTitles: [],
                        writtenFactBodies: []
                    )
                )
            }
        } catch {
            replace(id: assistantID, with: ChatViewModel.Turn(
                id: assistantID,
                speaker: .errorBubble,
                text: "Couldn't reach the assistant. Try again.",
                usedToolNames: nil
            ))
        }
    }

    func completeReview() async {
        if let row = try? scheduledActionService.action(id: action.id), row.status == .completed {
            return
        }
        let elapsed = Date().timeIntervalSince(firedAt)
        _ = try? await scheduledActionService.markCompleted(
            actionID: action.id,
            userResponseTime: elapsed
        )
    }

    func skipReview() async {
        try? await scheduledActionService.skipThisOccurrence(actionID: action.id)
    }

    // MARK: - Helpers

    private func recentTurnTexts() -> [String] {
        turns.suffix(6).compactMap { turn in
            guard turn.speaker != .errorBubble else { return nil }
            let prefix = (turn.speaker == .user) ? "User:" : "Assistant:"
            return "\(prefix) \(turn.text)"
        }
    }

    private func persistTurn(_ turn: ChatViewModel.Turn, role: MemoryTurn.Role) async throws {
        try await hema.writeTurn(MemoryTurn(
            id: turn.id,
            createdAt: Date(),
            chatSessionID: chatSessionID,
            role: role,
            content: turn.text,
            vector: nil
        ))
    }

    private func replace(id: UUID, with new: ChatViewModel.Turn) {
        if let i = turns.firstIndex(where: { $0.id == id }) {
            turns[i] = new
        }
    }

    private static func extractToolNames(from exchanges: [ToolExchange]) -> [String]? {
        let names = exchanges.map(\.toolName)
        return names.isEmpty ? nil : Array(Set(names)).sorted()
    }
}
