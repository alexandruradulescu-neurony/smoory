import Foundation
import SwiftData
import UserNotifications
import WidgetKit

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
        await fireFailureNotification(actionID: action?.id)
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
        // Belt-and-suspenders rate-limit enforcement (3.6 risk-3 mitigation): if the LLM
        // returned a goalNudge but the matching Goal was nudged within the last 7 days,
        // strip the nudge from the brief before persistence. The user never sees a
        // rate-limit-violating nudge even if the LLM ignored the prompt rule.
        let sanitizedBrief = stripIneligibleGoalNudge(brief)
        appGroupWriter?.writeMorningBrief(sanitizedBrief)

        let context = ModelContext(modelContainer)

        // Mark previous active morning briefs as actedUpon so the new one becomes
        // the only fresh row in Feed.
        markPreviousBriefsActedUpon(in: context, except: brief.id)

        let item = FeedItem()
        item.id = sanitizedBrief.id
        item.kind = .morningBrief
        item.priority = 100
        item.headline = sanitizedBrief.headline
        item.body = sanitizedBrief.reflectiveNote ?? ""
        item.state = .active
        item.createdAt = sanitizedBrief.generatedAt
        item.updatedAt = sanitizedBrief.generatedAt
        item.payloadJSON = encodeBriefJSON(sanitizedBrief)
        context.insert(item)
        try context.save()

        // Update Goal.lastNudgedAt for the goal that was nudged (if any) so the next
        // brief sees the rate-limit field populated. Logs and continues if the title
        // doesn't match a real Goal — see 3.5 post-test feedback where the LLM put a
        // fact body into goalTitle.
        if let nudge = sanitizedBrief.goalNudge {
            let title = nudge.goalTitle
            let goalDescriptor = FetchDescriptor<Goal>(
                predicate: #Predicate { $0.title == title }
            )
            if let goal = try? context.fetch(goalDescriptor).first {
                goal.lastNudgedAt = sanitizedBrief.generatedAt
                goal.updatedAt = sanitizedBrief.generatedAt
                try? context.save()
            } else {
                print("[brief] goalNudge.goalTitle '\(title)' didn't match a Goal entity — rate-limit not updated")
            }
        }

        Task { await fireHeadlineNotification(headline: sanitizedBrief.headline) }

        // Hint to WidgetKit so the desktop widget refreshes promptly rather than
        // waiting for its 15-minute timeline tick.
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Belt-and-suspenders rate limit. If the LLM returned a goalNudge for a goal that
    /// was nudged within the last 7 days, strip it from the brief before persistence.
    /// Returns the brief unchanged if the nudge is eligible or absent.
    private func stripIneligibleGoalNudge(_ brief: MorningBrief) -> MorningBrief {
        guard let nudge = brief.goalNudge else { return brief }
        let context = ModelContext(modelContainer)
        let title = nudge.goalTitle
        let descriptor = FetchDescriptor<Goal>(
            predicate: #Predicate { $0.title == title }
        )
        guard let goal = try? context.fetch(descriptor).first else {
            // Title doesn't match any Goal — strip it. The LLM is fabricating titles
            // (3.5 post-test feedback). Don't show the user a goal that doesn't exist.
            print("[brief] stripping goalNudge — title '\(title)' has no matching Goal entity")
            return Self.briefWithoutNudge(brief)
        }
        guard let last = goal.lastNudgedAt else { return brief }
        let elapsed = brief.generatedAt.timeIntervalSince(last)
        let weekSeconds: TimeInterval = 7 * 24 * 3600
        if elapsed < weekSeconds {
            print("[brief] stripping goalNudge — '\(title)' was nudged \(Int(elapsed / 86_400))d ago (rate limit 7d)")
            return Self.briefWithoutNudge(brief)
        }
        return brief
    }

    private static func briefWithoutNudge(_ brief: MorningBrief) -> MorningBrief {
        MorningBrief(
            id: brief.id,
            generatedAt: brief.generatedAt,
            forDate: brief.forDate,
            headline: brief.headline,
            secondaryItems: brief.secondaryItems,
            calendar: brief.calendar,
            reflectiveNote: brief.reflectiveNote,
            goalNudge: nil
        )
    }

    private func markPreviousBriefsActedUpon(in context: ModelContext, except keepID: UUID) {
        // SwiftData's @Predicate can't access enum .rawValue (see FeedView's note);
        // fetch all and filter client-side. Brief volume is ~1/day so this is fine.
        let descriptor = FetchDescriptor<FeedItem>()
        let rows = (try? context.fetch(descriptor)) ?? []
        var mutated = false
        for row in rows where row.kind == .morningBrief && row.state == .active && row.id != keepID {
            row.state = .actedUpon
            row.actedUponAt = Date()
            mutated = true
        }
        // Save here rather than relying on persist's later context.save(). Keeping the
        // write self-contained means the function doesn't go silently broken if the
        // caller's save flow ever changes.
        if mutated {
            try? context.save()
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
        // Headline fires post-completion. No actionID — instead a focus-feed intent so
        // the delegate routes the tap to the Feed surface without re-dispatching.
        content.userInfo = ["intent": "focusFeed"]
        content.interruptionLevel = .timeSensitive
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

    private func fireFailureNotification(actionID: UUID?) async {
        let content = UNMutableNotificationContent()
        content.title = "Smoory"
        content.body = "Brief generation failed — open Smoory to retry."
        content.sound = .default
        if let actionID {
            // Carry the actionID so a tap re-runs dispatch (single-flight collapses
            // concurrent triggers; row stays .firing until dispatch succeeds).
            content.userInfo = ["actionID": actionID.uuidString]
        }
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(
            identifier: "morning-brief-failure-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
