import Foundation
import SwiftData
import UserNotifications

enum MorningBriefError: Error, CustomStringConvertible {
    case generationFailed
    case noServiceAvailable

    var description: String {
        switch self {
        case .generationFailed: return "morning brief generation failed after retries"
        case .noServiceAvailable: return "scheduled action service unavailable"
        }
    }
}

/// Drives a single morning-brief generation. Stateless across runs; instantiated by
/// MorningBriefDispatcher per fire. Builds a fresh Orchestrator with a per-generation
/// session ID so brief tool calls don't pollute main chat or day-review hema turns.
@MainActor
final class MorningBriefGenerator {
    private let modelContainer: ModelContainer
    private let hema: HemaService
    private let calendarService: CalendarService
    private let appGroupWriter: AppGroupContainerWriter?
    private let scheduledActionService: ScheduledActionService
    private let client: LLMClient

    init(
        modelContainer: ModelContainer,
        hema: HemaService,
        calendarService: CalendarService,
        appGroupWriter: AppGroupContainerWriter?,
        scheduledActionService: ScheduledActionService,
        client: LLMClient = RoutingLLMClient()
    ) {
        self.modelContainer = modelContainer
        self.hema = hema
        self.calendarService = calendarService
        self.appGroupWriter = appGroupWriter
        self.scheduledActionService = scheduledActionService
        self.client = client
    }

    /// Generate a brief, persist it, fire a fresh notification with headline as body.
    /// On generation success, returns the brief; throws otherwise.
    func generate(forAction action: ScheduledAction? = nil, now: Date = Date()) async throws -> MorningBrief {
        let services = ToolServices(
            calendarService: calendarService,
            modelContainer: modelContainer,
            hema: hema,
            scheduledActionService: scheduledActionService
        )
        // Per 3.4 risk-2 mitigation: brief generator gets headroom (8 rounds) for
        // calendar + todos + goals + retrieve_memory + any follow-ups, while the
        // global default stays at 5 to keep main chat tight.
        let orchestrator = Orchestrator(
            client: client,
            registry: ToolRegistry.allTools,
            services: services,
            chatSessionID: UUID(),
            maxToolCallRounds: 8
        )

        let userMessage = "Generate today's morning brief. Return JSON only."
        let forDate = (action?.scheduledFor).map { Calendar.current.startOfDay(for: $0) } ?? Calendar.current.startOfDay(for: now)

        // First attempt — strict prompt.
        if let brief = try await attempt(
            orchestrator: orchestrator,
            systemPrompt: MorningBriefPrompts.systemPrompt,
            userMessage: userMessage,
            generatedAt: now,
            forDate: forDate
        ) {
            try persist(brief)
            return brief
        }

        MorningBriefFailureCounter.shared.increment()
        print("[brief] first attempt failed JSON parse; retrying with stricter prompt")

        let stricter = MorningBriefPrompts.systemPrompt + "\n\n" + MorningBriefPrompts.retryAddendum
        if let brief = try await attempt(
            orchestrator: orchestrator,
            systemPrompt: stricter,
            userMessage: userMessage,
            generatedAt: now,
            forDate: forDate
        ) {
            try persist(brief)
            return brief
        }

        MorningBriefFailureCounter.shared.increment()
        await fireFailureNotification()
        throw MorningBriefError.generationFailed
    }

    private func attempt(
        orchestrator: Orchestrator,
        systemPrompt: String,
        userMessage: String,
        generatedAt: Date,
        forDate: Date
    ) async throws -> MorningBrief? {
        let result = try await orchestrator.send(
            systemPrompt: systemPrompt,
            history: [],
            userMessage: userMessage,
            modelTier: .balanced,
            assistantTurnID: UUID()
        )
        return MorningBriefPrompts.parse(result.finalText, generatedAt: generatedAt, forDate: forDate)
    }

    private func persist(_ brief: MorningBrief) throws {
        appGroupWriter?.writeMorningBrief(brief)

        let context = ModelContext(modelContainer)

        // Mark previous active morning briefs as actedUpon so the new one becomes
        // the only fresh row in Feed.
        markPreviousBriefsActedUpon(in: context, except: brief.id)

        let item = FeedItem()
        item.id = brief.id
        item.kind = .morningBrief
        item.priority = 100
        item.headline = brief.headline
        item.body = brief.reflectiveNote ?? ""
        item.state = .active
        item.createdAt = brief.generatedAt
        item.updatedAt = brief.generatedAt
        item.payloadJSON = encodeBriefJSON(brief)
        context.insert(item)
        try context.save()

        Task { await fireHeadlineNotification(headline: brief.headline) }
    }

    private func markPreviousBriefsActedUpon(in context: ModelContext, except keepID: UUID) {
        // SwiftData's @Predicate can't access enum .rawValue (see FeedView's note);
        // fetch all and filter client-side. Brief volume is ~1/day so this is fine.
        let descriptor = FetchDescriptor<FeedItem>()
        let rows = (try? context.fetch(descriptor)) ?? []
        for row in rows where row.kind == .morningBrief && row.state == .active && row.id != keepID {
            row.state = .actedUpon
            row.actedUponAt = Date()
        }
    }

    private func encodeBriefJSON(_ brief: MorningBrief) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(brief),
              let str = String(data: data, encoding: .utf8)
        else { return "" }
        return str
    }

    // MARK: - Notification firing

    private func fireHeadlineNotification(headline: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Smoory"
        content.body = headline
        content.sound = .default
        content.categoryIdentifier = ScheduledActionService.notificationCategoryID
        let request = UNNotificationRequest(
            identifier: "morning-brief-fresh-\(UUID().uuidString)",
            content: content,
            trigger: nil  // immediate
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            print("[brief] headline notification failed: \(error)")
        }
    }

    private func fireFailureNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "Smoory"
        content.body = "Brief generation failed — open Smoory to retry."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "morning-brief-failure-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
