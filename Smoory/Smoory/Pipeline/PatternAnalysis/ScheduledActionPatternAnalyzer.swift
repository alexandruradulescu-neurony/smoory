import Foundation
import SwiftData

enum PatternAnalyzerError: Error, CustomStringConvertible {
    case analysisFailed
    var description: String {
        switch self {
        case .analysisFailed: return "pattern analysis failed after retries"
        }
    }
}

@MainActor
final class ScheduledActionPatternAnalyzer {
    private let modelContainer: ModelContainer
    private let scheduledActionService: ScheduledActionService
    private let hema: HemaService
    private let calendarService: CalendarService
    private let client: LLMClient

    init(
        modelContainer: ModelContainer,
        scheduledActionService: ScheduledActionService,
        hema: HemaService,
        calendarService: CalendarService,
        client: LLMClient = RoutingLLMClient()
    ) {
        self.modelContainer = modelContainer
        self.scheduledActionService = scheduledActionService
        self.hema = hema
        self.calendarService = calendarService
        self.client = client
    }

    /// Analyze the last 7 days of scheduled action history. Two-attempt JSON retry
    /// pattern mirroring MorningBriefGenerator. Throws on second failure.
    func analyze(now: Date = Date()) async throws -> PatternAnalysis {
        let cal = Calendar.current
        // Anchor weekEnd to the start of today so the labelled range doesn't drift
        // when the analyzer fires at different clock times across weeks. weekStart is
        // exactly 7 days earlier — a clean, contiguous 7-day window ending at midnight
        // local time. Sufficient for the user's recurring weekly rhythm; previous
        // implementation rolled "from now" which caused the displayed range to slip
        // a day forward when the review fired late in the evening.
        let weekEnd = cal.startOfDay(for: now)
        let weekStart = cal.date(byAdding: .day, value: -7, to: weekEnd) ?? weekEnd

        let history = (try? scheduledActionService.actionsHistory(daysBack: 7)) ?? []
        let stats = computeStats(history: history)
        let userMessage = PatternAnalysisPrompts.buildUserMessage(
            stats: stats,
            history: history,
            weekStart: weekStart,
            weekEnd: weekEnd
        )

        // No tools needed — pure stats + LLM. Services bag is required by Orchestrator's
        // constructor; the analyzer's empty registry means none of these are actually
        // exercised during the call.
        let services = ToolServices(
            calendarService: calendarService,
            modelContainer: modelContainer,
            hema: hema,
            scheduledActionService: scheduledActionService
        )
        let orchestrator = Orchestrator(
            client: client,
            registry: [],          // no tools — analyzer is a single LLM call
            services: services,
            chatSessionID: UUID(),
            maxToolCallRounds: 1
        )

        // First attempt — strict prompt.
        if let analysis = try await attempt(
            orchestrator: orchestrator,
            systemPrompt: PatternAnalysisPrompts.systemPrompt,
            userMessage: userMessage,
            analyzedAt: now,
            weekStart: weekStart,
            weekEnd: weekEnd,
            stats: stats
        ) {
            return analysis
        }

        PatternAnalyzerFailureCounter.shared.increment()
        print("[pattern] first attempt failed JSON parse; retrying with stricter prompt")

        let stricter = PatternAnalysisPrompts.systemPrompt + "\n\n" + PatternAnalysisPrompts.retryAddendum
        if let analysis = try await attempt(
            orchestrator: orchestrator,
            systemPrompt: stricter,
            userMessage: userMessage,
            analyzedAt: now,
            weekStart: weekStart,
            weekEnd: weekEnd,
            stats: stats
        ) {
            return analysis
        }

        PatternAnalyzerFailureCounter.shared.increment()
        throw PatternAnalyzerError.analysisFailed
    }

    private func attempt(
        orchestrator: Orchestrator,
        systemPrompt: String,
        userMessage: String,
        analyzedAt: Date,
        weekStart: Date,
        weekEnd: Date,
        stats: WeekStats
    ) async throws -> PatternAnalysis? {
        let result = try await orchestrator.send(
            systemPrompt: systemPrompt,
            history: [],
            userMessage: userMessage,
            modelTier: .balanced,
            assistantTurnID: UUID()
        )
        return PatternAnalysisPrompts.parse(
            result.finalText,
            analyzedAt: analyzedAt,
            weekStart: weekStart,
            weekEnd: weekEnd,
            stats: stats
        )
    }

    // MARK: - Stats computation

    func computeStats(history: [ScheduledAction]) -> WeekStats {
        let reminders = history.filter { $0.kind == .userReminder }
        let completed = reminders.filter { $0.status == .completed }
        let skipped = reminders.filter { $0.status == .skipped }
        let postponed = reminders.filter { $0.deferralCount > 0 }
        let dayReviewsCompleted = history.filter {
            $0.kind == .dayReview && $0.status == .completed
        }.count

        let responseTimes = history
            .filter { $0.status == .completed }
            .compactMap(\.userResponseTimeSeconds)
        let avgResponse: TimeInterval? = responseTimes.isEmpty
            ? nil
            : responseTimes.reduce(0, +) / TimeInterval(responseTimes.count)

        // Stable tiebreak: highest deferralCount first, then earliest scheduledFor so
        // ties resolve deterministically across runs. Without this, observations
        // referencing "most deferred" can flip week-to-week without underlying change.
        let mostDeferred = history
            .filter { $0.deferralCount > 0 }
            .max {
                if $0.deferralCount != $1.deferralCount {
                    return $0.deferralCount < $1.deferralCount
                }
                return $0.scheduledFor > $1.scheduledFor
            }
            .map(\.content)

        return WeekStats(
            totalReminders: reminders.count,
            completedReminders: completed.count,
            skippedReminders: skipped.count,
            postponedReminders: postponed.count,
            dayReviewsCompleted: dayReviewsCompleted,
            avgUserResponseTime: avgResponse,
            mostDeferredAction: mostDeferred
        )
    }

}
