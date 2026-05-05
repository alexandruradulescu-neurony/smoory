import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class WeekReviewViewModel {
    private(set) var turns: [ChatViewModel.Turn] = []
    private(set) var isSending: Bool = false
    private(set) var shouldDismiss: Bool = false
    private(set) var summary: WeekReviewSummary?
    private(set) var isAnalyzing: Bool = false
    var draft: String = ""

    private let action: ScheduledAction
    private let chatSessionID: UUID = UUID()
    private let modelContainer: ModelContainer
    private let orchestrator: Orchestrator
    private let scheduledActionService: ScheduledActionService
    private let hema: HemaService
    private let structuringService: StructuringService
    private let patternAnalyzer: ScheduledActionPatternAnalyzer
    private let compactMemoryGenerator: CompactMemoryGenerator?
    private let firedAt: Date = Date()

    init(
        action: ScheduledAction,
        modelContainer: ModelContainer,
        hema: HemaService,
        scheduledActionService: ScheduledActionService,
        client: LLMClient = RoutingLLMClient(),
        calendarService: CalendarService? = nil,
        compactMemoryGenerator: CompactMemoryGenerator? = nil
    ) {
        self.action = action
        self.modelContainer = modelContainer
        self.hema = hema
        self.scheduledActionService = scheduledActionService
        self.compactMemoryGenerator = compactMemoryGenerator

        let resolvedCalendar = calendarService ?? CalendarService()
        let services = ToolServices(
            calendarService: resolvedCalendar,
            modelContainer: modelContainer,
            hema: hema,
            scheduledActionService: scheduledActionService
        )
        self.orchestrator = Orchestrator(
            client: client,
            registry: ToolRegistry.allTools,
            services: services,
            chatSessionID: chatSessionID
        )
        self.structuringService = StructuringService(client: client, modelContainer: modelContainer)
        self.patternAnalyzer = ScheduledActionPatternAnalyzer(
            modelContainer: modelContainer,
            scheduledActionService: scheduledActionService,
            hema: hema,
            calendarService: resolvedCalendar,
            client: client
        )
    }

    func startIfNeeded() async {
        guard turns.isEmpty else { return }
        _ = try? scheduledActionService.markFiring(actionID: action.id)

        // Run pattern analysis FIRST so the opener can reference observations.
        // If the user opened this sheet before for the same scheduled action, reuse
        // the persisted summary instead of re-running the LLM and re-emitting
        // CandidateWrite rows for the same insights.
        // UI audit fix #20: cap analysis at 60 seconds. Pre-fix, an LLM stall could
        // hang `isAnalyzing` indefinitely with no fallback — the AnalyzingView would
        // show forever. Now we race against a timeout and fall back to a no-summary
        // opener if the analyzer doesn't return.
        isAnalyzing = true
        let result = await withAnalysisTimeout(seconds: 60) {
            await self.loadOrAnalyze()
        }
        self.summary = result.summary
        isAnalyzing = false

        // Surface durable insights as Feed candidates ONLY on first analysis. A reload
        // of an existing summary means insights were already surfaced previously.
        if result.isNewAnalysis, let row = result.summary {
            await surfaceInsightsAsCandidates(row.durableInsights, summaryID: row.id)
        }

        let opener = WeekReviewPrompts.makeOpener(summary: result.summary)
        let openerTurn = ChatViewModel.Turn(id: UUID(), speaker: .assistant, text: opener, usedToolNames: nil)
        turns.append(openerTurn)
        Task { try? await persistTurn(openerTurn, role: .assistant) }
    }

    /// Idempotent. Returns the existing WeekReviewSummary for this action (if any), or
    /// runs analysis and persists a fresh row. `isNewAnalysis` lets the caller decide
    /// whether to re-surface CandidateWrite rows (avoid duplication on re-open).
    private func loadOrAnalyze() async -> (summary: WeekReviewSummary?, isNewAnalysis: Bool) {
        if let existing = fetchExistingSummary() {
            print("[week-review] reusing existing summary \(existing.id) for action \(action.id)")
            return (existing, false)
        }
        do {
            let analysis = try await patternAnalyzer.analyze()
            let context = ModelContext(modelContainer)
            let row = WeekReviewSummary()
            row.actionID = action.id
            row.weekStartedAt = analysis.weekStartedAt
            row.weekEndedAt = analysis.weekEndedAt
            row.generatedAt = analysis.analyzedAt
            row.statsJSON = encode(analysis.stats) ?? "{}"
            row.observationsJSON = encode(analysis.observations) ?? "[]"
            row.durableInsightsJSON = encode(analysis.durableInsights) ?? "[]"
            context.insert(row)
            try context.save()
            return (row, true)
        } catch {
            print("[week-review] pattern analysis failed: \(error)")
            return (nil, false)
        }
    }

    private func fetchExistingSummary() -> WeekReviewSummary? {
        let context = ModelContext(modelContainer)
        let actionID = action.id
        let descriptor = FetchDescriptor<WeekReviewSummary>(
            predicate: #Predicate { $0.actionID == actionID }
        )
        return try? context.fetch(descriptor).first
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
                systemPrompt: WeekReviewPrompts.systemPrompt,
                history: Array(history),
                userMessage: trimmed,
                modelTier: .balanced,
                assistantTurnID: assistantID
            )

            let toolNames = Self.uniqueToolNames(result.toolExchanges)
            let final = ChatViewModel.Turn(
                id: assistantID,
                speaker: .assistant,
                text: result.finalText.isEmpty ? "(empty response)" : result.finalText,
                usedToolNames: toolNames
            )
            replace(id: assistantID, with: final)
            Task { try? await persistTurn(final, role: .assistant) }

            if result.toolExchanges.contains(where: { $0.toolName == CompleteWeekReviewTool.name }) {
                await completeReview()
                shouldDismiss = true
                return
            }

            // Structuring extraction so the week review's user turns surface candidates
            // in Feed (same pattern as day review).
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
        // Idempotent: completion can be triggered both by the LLM's complete_week_review
        // tool and by the Done button. Re-fetching the row protects userResponseTimeSeconds
        // from being overwritten with a much larger elapsed value on the second call.
        if let row = try? scheduledActionService.action(id: action.id), row.status == .completed {
            return
        }
        let elapsed = Date().timeIntervalSince(firedAt)
        _ = try? await scheduledActionService.markCompleted(actionID: action.id, userResponseTime: elapsed)

        // Compact memory regeneration hooks. Both run as detached tasks so the
        // sheet dismisses immediately; if the user closes the app before the
        // LLM call returns, that week's regeneration simply doesn't land — next
        // week's catches up.
        if let generator = compactMemoryGenerator {
            // .recent — every completed week review.
            Task.detached { @MainActor [generator] in
                do {
                    let memory = try await generator.generateRecent()
                    print("[compact] regenerated .recent (\(memory.wordCount) words)")
                } catch {
                    CompactMemoryFailureCounter.shared.increment()
                    print("[compact] .recent regeneration failed: \(error)")
                }
            }

            // .overall — gated on every 4th completed week review. completeReview
            // runs before this count is read, so the just-completed review is
            // included in the count.
            let count = (try? scheduledActionService.completedActions(of: .weekReview).count) ?? 0
            if count > 0 && count.isMultiple(of: 4) {
                Task.detached { @MainActor [generator] in
                    do {
                        let memory = try await generator.generateOverall()
                        print("[compact] regenerated .overall (\(memory.wordCount) words)")
                    } catch {
                        CompactMemoryFailureCounter.shared.increment()
                        print("[compact] .overall regeneration failed: \(error)")
                    }
                }
            }
        }
    }

    func skipReview() async {
        // The WeekReviewSummary written during startIfNeeded is intentionally kept on
        // skip — it captures the analyzer's reading of the week even if the user
        // didn't talk through it. No surface lists past summaries yet (Phase 4),
        // so it's invisible. When that surface lands, treat summaries with a skipped
        // actionID as "analyzed but not discussed".
        try? await scheduledActionService.skipThisOccurrence(actionID: action.id)
    }

    // MARK: - Helpers

    private func surfaceInsightsAsCandidates(_ insights: [DurableInsight], summaryID: UUID) async {
        let context = ModelContext(modelContainer)
        for insight in insights where insight.confidence >= 0.7 {
            let candidate = CandidateWrite()
            candidate.type = .fact
            candidate.content = insight.factText
            candidate.confidence = insight.confidence
            candidate.userPhrase = ""
            candidate.sourceSessionID = chatSessionID
            candidate.sourceTurnID = nil
            candidate.extractingModel = AIProviderStore.current().modelID(for: .balanced)
            candidate.sourceKind = "week_review_pattern_analysis"
            candidate.status = .pending
            context.insert(candidate)
        }
        try? context.save()
    }

    private func recentTurnTexts() -> [String] {
        turns.suffix(8).compactMap { turn in
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

    private static func uniqueToolNames(_ exchanges: [ToolExchange]) -> [String]? {
        let names = exchanges.map(\.toolName)
        return names.isEmpty ? nil : Array(Set(names)).sorted()
    }

    private func encode<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// UI audit fix #20: race the analyzer against a wall-clock timeout. If the
    /// analyzer doesn't return within `seconds`, drop into the no-summary fallback
    /// (`(nil, false)` so the opener uses the static prompt) instead of hanging the
    /// AnalyzingView forever.
    private func withAnalysisTimeout(
        seconds: TimeInterval,
        work: @escaping () async -> (summary: WeekReviewSummary?, isNewAnalysis: Bool)
    ) async -> (summary: WeekReviewSummary?, isNewAnalysis: Bool) {
        await withTaskGroup(of: (summary: WeekReviewSummary?, isNewAnalysis: Bool)?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return (nil, false)
            }
            // First non-nil result wins; cancel the rest.
            for await result in group {
                if let r = result {
                    group.cancelAll()
                    return r
                }
            }
            return (nil, false)
        }
    }
}
