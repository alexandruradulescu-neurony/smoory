import Foundation
import SwiftData
import UserNotifications
import WidgetKit

enum ScheduledActionError: Error {
    case notFound
}

/// Central authority on ScheduledAction lifecycle. All mutations route through here so
/// SwiftData rows and UNUserNotification requests stay in sync, and the App Group
/// snapshot is rewritten on every change.
@MainActor
final class ScheduledActionService {
    static let notificationCategoryID = "SMOORY_SCHEDULED_ACTION"

    private let modelContainer: ModelContainer
    private let notificationCenter: UNUserNotificationCenter
    private let appGroupWriter: AppGroupContainerWriter?

    init(
        modelContainer: ModelContainer,
        notificationCenter: UNUserNotificationCenter = .current(),
        appGroupWriter: AppGroupContainerWriter?
    ) {
        self.modelContainer = modelContainer
        self.notificationCenter = notificationCenter
        self.appGroupWriter = appGroupWriter
    }

    // MARK: - Create

    @discardableResult
    func schedule(
        kind: ScheduledActionKind,
        at scheduledFor: Date,
        content: String = "",
        recurringRule: RecurringRule? = nil,
        relatedEntityID: UUID? = nil,
        source: ActionSource
    ) async throws -> ScheduledAction {
        let context = ModelContext(modelContainer)
        let row = ScheduledAction()
        row.kind = kind
        row.scheduledFor = scheduledFor
        row.originalScheduledFor = scheduledFor
        row.status = .pending
        row.createdBySource = source
        row.content = content
        row.recurringRule = recurringRule
        row.relatedEntityID = relatedEntityID
        context.insert(row)
        try context.save()

        await scheduleNotification(for: row)
        await writeSnapshot()
        return row
    }

    // MARK: - Mutate

    @discardableResult
    func postpone(actionID: UUID, by interval: TimeInterval, reason: String?) async throws -> ScheduledAction {
        let context = ModelContext(modelContainer)
        let row = try Self.fetch(actionID, in: context)

        let now = Date()
        let from = row.scheduledFor
        // Bug-fix follow-up: anchor the new scheduledFor to max(now, from) before
        // adding the offset. Otherwise a "+10 min" tap at 09:30 on a reminder that
        // fired at 09:00 would push the new time to 09:10 (already past), and the
        // polling tick would re-fire it almost immediately. The user expects "+10
        // min from now" semantics regardless of how late they snoozed.
        let anchor = max(from, now)
        let to = anchor.addingTimeInterval(interval)

        row.scheduledFor = to
        row.deferralCount += 1
        var history = row.deferralHistory
        history.append(DeferralEntry(at: now, fromTime: from, toTime: to, reason: reason))
        row.deferralHistory = history
        row.status = .pending
        try context.save()

        await cancelNotification(id: row.id)
        await scheduleNotification(for: row)
        await writeSnapshot()
        return row
    }

    @discardableResult
    func reschedule(actionID: UUID, to newTime: Date, reason: String?) async throws -> ScheduledAction {
        let context = ModelContext(modelContainer)
        let row = try Self.fetch(actionID, in: context)

        let from = row.scheduledFor
        row.scheduledFor = newTime
        row.deferralCount += 1
        var history = row.deferralHistory
        history.append(DeferralEntry(at: Date(), fromTime: from, toTime: newTime, reason: reason))
        row.deferralHistory = history
        row.status = .pending
        try context.save()

        await cancelNotification(id: row.id)
        await scheduleNotification(for: row)
        await writeSnapshot()
        return row
    }

    func cancel(actionID: UUID) async throws {
        let context = ModelContext(modelContainer)
        let row = try Self.fetch(actionID, in: context)
        row.status = .cancelled
        try context.save()

        await cancelNotification(id: row.id)
        await writeSnapshot()
    }

    /// Skip just this occurrence. For one-off rows: equivalent to cancel (status .skipped,
    /// no regeneration). For recurring rows: marks .skipped and generates the next
    /// occurrence per the rule. Distinct from `cancel`, which kills the entire recurring
    /// thread.
    func skipThisOccurrence(actionID: UUID) async throws {
        let context = ModelContext(modelContainer)
        let row = try Self.fetch(actionID, in: context)
        row.status = .skipped
        try context.save()

        await cancelNotification(id: row.id)

        if let rule = row.recurringRule, rule.kind != .none {
            try await regenerateNextOccurrence(of: row, in: context)
        }

        await writeSnapshot()
    }

    @discardableResult
    func markFiring(actionID: UUID) throws -> ScheduledAction {
        let context = ModelContext(modelContainer)
        let row = try Self.fetch(actionID, in: context)
        // Bug-fix follow-up: only flip to .firing from .pending. Without this guard a
        // tap on an already-delivered notification (still sitting in Notification
        // Center) for an action the user already completed/skipped/cancelled would
        // resurrect it as .firing and the consumer would re-present the modal.
        switch row.status {
        case .pending, .firing, .deferred:
            row.status = .firing
            try context.save()
        case .completed, .cancelled, .skipped:
            // No-op. Caller's downstream branches see the existing terminal status
            // and route appropriately (NotificationDelegate logs + drops the tap).
            break
        }
        return row
    }

    @discardableResult
    func markCompleted(actionID: UUID, userResponseTime: TimeInterval?) async throws -> ScheduledAction {
        let context = ModelContext(modelContainer)
        let row = try Self.fetch(actionID, in: context)
        row.status = .completed
        let now = Date()
        row.completedAt = now
        // If caller didn't compute it, derive from scheduledFor.
        row.userResponseTimeSeconds = userResponseTime ?? now.timeIntervalSince(row.scheduledFor)
        try context.save()

        if let rule = row.recurringRule, rule.kind != .none {
            try await regenerateNextOccurrence(of: row, in: context)
        }

        await writeSnapshot()
        return row
    }

    func cancelAll() async throws {
        let context = ModelContext(modelContainer)
        let rows = try context.fetch(FetchDescriptor<ScheduledAction>())
        for row in rows {
            row.status = .cancelled
        }
        try context.save()

        notificationCenter.removeAllPendingNotificationRequests()
        await writeSnapshot()
    }

    // MARK: - Query

    func pendingActions(within: TimeInterval = 86_400) throws -> [ScheduledAction] {
        let context = ModelContext(modelContainer)
        let cutoff = Date().addingTimeInterval(within)
        let pendingRaw = ScheduledActionStatus.pending.rawValue
        var descriptor = FetchDescriptor<ScheduledAction>(
            predicate: #Predicate { $0.statusRaw == pendingRaw && $0.scheduledFor <= cutoff },
            sortBy: [SortDescriptor(\.scheduledFor, order: .forward)]
        )
        descriptor.fetchLimit = 100
        return try context.fetch(descriptor)
    }

    func dueActions(asOf now: Date = Date()) throws -> [ScheduledAction] {
        let context = ModelContext(modelContainer)
        let pendingRaw = ScheduledActionStatus.pending.rawValue
        let descriptor = FetchDescriptor<ScheduledAction>(
            predicate: #Predicate { $0.statusRaw == pendingRaw && $0.scheduledFor <= now },
            sortBy: [SortDescriptor(\.scheduledFor, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    func actionsHistory(daysBack: Int = 7) throws -> [ScheduledAction] {
        let context = ModelContext(modelContainer)
        let cutoff = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
        // Filter by scheduledFor, not createdAt. Recurring rows are recreated per
        // occurrence (regenerateNextOccurrence) so scheduledFor reflects the actual
        // event date for each row. createdAt could be months in the past for a long-
        // running recurring schedule, masking recently-fired rows from the analyzer.
        let descriptor = FetchDescriptor<ScheduledAction>(
            predicate: #Predicate { $0.scheduledFor >= cutoff },
            sortBy: [SortDescriptor(\.scheduledFor, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    /// Returns all `.completed` scheduled actions of the given kind, sorted by
    /// completedAt descending. Used by compact-memory regeneration to gate the
    /// every-Nth-completion `.overall` refresh after a week review.
    func completedActions(of kind: ScheduledActionKind) throws -> [ScheduledAction] {
        let context = ModelContext(modelContainer)
        let kindRaw = kind.rawValue
        let completedRaw = ScheduledActionStatus.completed.rawValue
        let descriptor = FetchDescriptor<ScheduledAction>(
            predicate: #Predicate {
                $0.kindRaw == kindRaw && $0.statusRaw == completedRaw
            },
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    /// Direct fetch by row id. Used by notification routing where the action id is
    /// already known and a history scan is wasteful.
    func action(id: UUID) throws -> ScheduledAction? {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<ScheduledAction>(
            predicate: #Predicate { $0.id == id }
        )
        return try context.fetch(descriptor).first
    }

    func nextScheduledAction() throws -> ScheduledAction? {
        let context = ModelContext(modelContainer)
        let pendingRaw = ScheduledActionStatus.pending.rawValue
        var descriptor = FetchDescriptor<ScheduledAction>(
            predicate: #Predicate { $0.statusRaw == pendingRaw },
            sortBy: [SortDescriptor(\.scheduledFor, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: - Background processing

    /// Skips review-kind rows (.dayReview / .endOfDay / .weekReview) whose
    /// `scheduledFor` is older than `cutoffSeconds`, regardless of whether
    /// they're still .pending or already .firing. Skipping triggers
    /// `regenerateNextOccurrence` for recurring rules so the daily/weekly
    /// chain advances even when the user never tapped the OS notification.
    /// Without this, a single missed-and-untapped review stalls the whole
    /// recurring thread (regen only fires on markCompleted/skipThisOccurrence).
    /// Default cutoff = 18h: a review missed last night auto-skips by mid-
    /// afternoon the next day, leaving the morning to act on it via the Feed
    /// "Reviews" surface.
    func skipStaleReviewMisses(
        now: Date = Date(),
        cutoffSeconds: TimeInterval = 18 * 3600
    ) async {
        let cutoff = now.addingTimeInterval(-cutoffSeconds)
        let context = ModelContext(modelContainer)
        let pendingRaw = ScheduledActionStatus.pending.rawValue
        let firingRaw = ScheduledActionStatus.firing.rawValue
        let dayReviewRaw = ScheduledActionKind.dayReview.rawValue
        let endOfDayRaw = ScheduledActionKind.endOfDay.rawValue
        let weekReviewRaw = ScheduledActionKind.weekReview.rawValue
        let descriptor = FetchDescriptor<ScheduledAction>(
            predicate: #Predicate {
                ($0.statusRaw == pendingRaw || $0.statusRaw == firingRaw)
                    && ($0.kindRaw == dayReviewRaw
                        || $0.kindRaw == endOfDayRaw
                        || $0.kindRaw == weekReviewRaw)
                    && $0.scheduledFor < cutoff
            }
        )
        guard let stale = try? context.fetch(descriptor), !stale.isEmpty else { return }
        for row in stale {
            do {
                try await skipThisOccurrence(actionID: row.id)
            } catch {
                print("[scheduled] skipStaleReviewMisses: skip \(row.id) failed: \(error)")
            }
        }
        print("[scheduled] skipStaleReviewMisses: skipped \(stale.count) stale review row(s)")
    }

    /// Flips any pending-and-overdue rows to .firing. Called from the foreground polling
    /// timer and on app launch. Errors are logged and swallowed — this runs without a
    /// caller to surface failures to.
    func processOverdue(now: Date = Date()) async {
        do {
            let due = try dueActions(asOf: now)
            guard !due.isEmpty else { return }
            for row in due {
                _ = try? markFiring(actionID: row.id)
            }
            await writeSnapshot()
            print("[scheduled] processOverdue flipped \(due.count) row(s) to .firing")
        } catch {
            print("[scheduled] processOverdue failed: \(error)")
        }
    }

    // MARK: - Recurring regeneration

    private func regenerateNextOccurrence(of row: ScheduledAction, in context: ModelContext) async throws {
        guard let rule = row.recurringRule, rule.kind != .none else { return }
        let nextTime = Self.nextOccurrenceTime(
            rule: rule,
            after: row.originalScheduledFor,
            now: Date()
        )

        let next = ScheduledAction()
        next.kind = row.kind
        next.scheduledFor = nextTime
        next.originalScheduledFor = nextTime
        next.status = .pending
        next.createdBySource = row.createdBySource
        next.content = row.content
        next.recurringRule = rule
        next.relatedEntityID = row.relatedEntityID
        context.insert(next)
        try context.save()

        await scheduleNotification(for: next)
    }

    /// Calculates the next fire time for a recurring rule. Anchors on the *original*
    /// scheduled time so a single-occurrence postponement doesn't drift the recurrence.
    /// The result is guaranteed to be strictly after `now` — for backlog (app closed
    /// for days), the loop advances by one increment until it lands in the future.
    static func nextOccurrenceTime(rule: RecurringRule, after originalScheduledFor: Date, now: Date) -> Date {
        let cal = Calendar.current
        var candidate = originalScheduledFor

        switch rule.kind {
        case .none:
            return originalScheduledFor

        case .daily:
            repeat {
                candidate = cal.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            } while candidate <= now
            return candidate

        case .weekly:
            repeat {
                candidate = cal.date(byAdding: .day, value: 7, to: candidate) ?? candidate
            } while candidate <= now
            return candidate

        case .weekdays:
            // Step day-by-day, skipping Sat (7) and Sun (1), until candidate is in the
            // future and on a weekday.
            repeat {
                candidate = cal.date(byAdding: .day, value: 1, to: candidate) ?? candidate
                while [1, 7].contains(cal.component(.weekday, from: candidate)) {
                    candidate = cal.date(byAdding: .day, value: 1, to: candidate) ?? candidate
                }
            } while candidate <= now
            return candidate
        }
    }

    // MARK: - Helpers

    private static func fetch(_ id: UUID, in context: ModelContext) throws -> ScheduledAction {
        let descriptor = FetchDescriptor<ScheduledAction>(predicate: #Predicate { $0.id == id })
        guard let row = try context.fetch(descriptor).first else {
            throw ScheduledActionError.notFound
        }
        return row
    }

    private func writeSnapshot() async {
        guard let writer = appGroupWriter else { return }
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<ScheduledAction>(
            sortBy: [SortDescriptor(\.scheduledFor, order: .forward)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        writer.writeScheduledActionsSnapshot(rows)
        // Single integration point — every mutating method routes through
        // writeSnapshot, so the widget refresh hint reaches all 8 call sites
        // (schedule / postpone / reschedule / cancel / skipThisOccurrence /
        // markCompleted / cancelAll / processOverdue's snapshot rewrite).
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Notification scheduling

    private func scheduleNotification(for action: ScheduledAction) async {
        // Morning briefs suppress the OS-scheduled notification — generation latency
        // means the OS would fire "Your morning brief is ready" before the brief
        // actually exists. The MorningBriefDispatcher fires a fresh notification with
        // the headline as body once generation completes.
        guard action.kind != .morningBrief else { return }

        let content = UNMutableNotificationContent()
        content.title = "Smoory"
        content.body = body(for: action)
        content.sound = .default
        content.categoryIdentifier = Self.notificationCategoryID
        content.userInfo = ["actionID": action.id.uuidString]
        // Time-sensitive breaks through Focus and biases macOS toward Alert-style
        // presentation. The user must still pick "Alerts" in System Settings →
        // Notifications → Smoory for banners to stay on screen until dismissed.
        content.interruptionLevel = .timeSensitive

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: action.scheduledFor
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)

        let request = UNNotificationRequest(
            identifier: action.id.uuidString,
            content: content,
            trigger: trigger
        )

        do {
            try await notificationCenter.add(request)
        } catch {
            // Permission denied or category not registered — data write is the source of
            // truth, foreground polling still flips status. Log and continue.
            print("[scheduled] notification add failed for \(action.id): \(error)")
        }
    }

    private func cancelNotification(id: UUID) async {
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [id.uuidString])
        notificationCenter.removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    private func body(for action: ScheduledAction) -> String {
        if !action.content.isEmpty { return action.content }
        switch action.kind {
        case .morningBrief: return "Your morning brief is ready"
        case .dayReview:    return "Time for the day review?"
        case .weekReview:   return "Sunday — week review?"
        case .goalNudge:    return "Goal check-in"
        case .userReminder: return "Reminder"
        case .endOfDay:     return "Closing out — anything left from today?"
        }
    }
}
