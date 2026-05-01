import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class WeekReviewSettingsViewModel {
    var weekReviewEnabled: Bool = false {
        didSet { applyChanges() }
    }
    var weekReviewDayOfWeek: Int {     // 1 = Sunday … 7 = Saturday (Calendar's 1-based weekday)
        didSet { applyChanges() }
    }
    var weekReviewTime: Date {
        didSet { applyChanges() }
    }

    private let modelContainer: ModelContainer
    private let service: ScheduledActionService?
    private var isLoading: Bool = false
    private var debounceTask: Task<Void, Never>?

    init(modelContainer: ModelContainer, service: ScheduledActionService?) {
        self.modelContainer = modelContainer
        self.service = service
        self.weekReviewDayOfWeek = 1            // Sunday default
        self.weekReviewTime = Self.defaultPickerTime()
        loadCurrentState()
    }

    private func loadCurrentState() {
        isLoading = true
        defer { isLoading = false }
        guard let row = currentRecurringWeekReview() else {
            weekReviewEnabled = false
            weekReviewDayOfWeek = 1
            weekReviewTime = Self.defaultPickerTime()
            return
        }
        weekReviewEnabled = true
        if let rule = row.recurringRule {
            weekReviewDayOfWeek = rule.dayOfWeek ?? 1
            weekReviewTime = Self.dateFromTimeOfDay(rule.timeOfDay) ?? row.scheduledFor
        } else {
            weekReviewTime = row.scheduledFor
        }
    }

    private func applyChanges() {
        guard !isLoading else { return }
        debounceTask?.cancel()
        let snapshotEnabled = weekReviewEnabled
        let snapshotDay = weekReviewDayOfWeek
        let snapshotTime = weekReviewTime
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            await reconcile(enabled: snapshotEnabled, day: snapshotDay, time: snapshotTime)
        }
    }

    private func reconcile(enabled: Bool, day: Int, time: Date) async {
        guard let service else {
            print("[settings] ScheduledActionService unavailable; cannot reconcile week review")
            return
        }
        // Cancel any stale one-off week reviews regardless of branch — the settings UI
        // is the source of truth and a debug-seeded or legacy one-off shouldn't fire
        // alongside the recurring schedule. Only the recurring row should remain.
        await cancelOneOffWeekReviews(service: service)

        let existing = currentRecurringWeekReview()
        switch (enabled, existing) {
        case (false, nil):
            return
        case (false, let row?):
            try? await service.cancel(actionID: row.id)
        case (true, nil):
            await scheduleNew(day: day, time: time, service: service)
        case (true, let row?):
            try? await service.cancel(actionID: row.id)
            await scheduleNew(day: day, time: time, service: service)
        }
    }

    private func cancelOneOffWeekReviews(service: ScheduledActionService) async {
        let context = ModelContext(modelContainer)
        let pendingRaw = ScheduledActionStatus.pending.rawValue
        let kindRaw = ScheduledActionKind.weekReview.rawValue
        let descriptor = FetchDescriptor<ScheduledAction>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.statusRaw == pendingRaw }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        for row in rows where row.recurringRuleJSON == nil {
            try? await service.cancel(actionID: row.id)
        }
    }

    private func scheduleNew(day: Int, time: Date, service: ScheduledActionService) async {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        let firstFire = Self.nextFire(weekday: day, hourMinute: comps, after: Date())
        let rule = RecurringRule(kind: .weekly, timeOfDay: comps, dayOfWeek: day)
        do {
            _ = try await service.schedule(
                kind: .weekReview,
                at: firstFire,
                content: "",
                recurringRule: rule,
                relatedEntityID: nil,
                source: .system
            )
        } catch {
            print("[settings] failed to schedule week review: \(error)")
        }
    }

    private func currentRecurringWeekReview() -> ScheduledAction? {
        let context = ModelContext(modelContainer)
        let pendingRaw = ScheduledActionStatus.pending.rawValue
        let kindRaw = ScheduledActionKind.weekReview.rawValue
        let descriptor = FetchDescriptor<ScheduledAction>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.statusRaw == pendingRaw },
            sortBy: [SortDescriptor(\.scheduledFor, order: .forward)]
        )
        return (try? context.fetch(descriptor))?.first { $0.recurringRuleJSON != nil }
    }

    // MARK: - Static helpers

    private static func defaultPickerTime() -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 17
        comps.minute = 0
        return Calendar.current.date(from: comps) ?? Date()
    }

    private static func dateFromTimeOfDay(_ tod: DateComponents) -> Date? {
        guard let hour = tod.hour, let minute = tod.minute else { return nil }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        return Calendar.current.date(from: comps)
    }

    /// Next occurrence of the given weekday + HH:MM strictly after `now`.
    private static func nextFire(weekday: Int, hourMinute: DateComponents, after now: Date) -> Date {
        let cal = Calendar.current
        var matching = DateComponents()
        matching.weekday = weekday
        matching.hour = hourMinute.hour
        matching.minute = hourMinute.minute
        matching.second = 0
        return cal.nextDate(after: now, matching: matching, matchingPolicy: .nextTime) ?? now.addingTimeInterval(86_400)
    }

    static func weekdayName(_ day: Int) -> String {
        let symbols = Calendar.current.standaloneWeekdaySymbols
        guard day >= 1, day <= symbols.count else { return "Day \(day)" }
        return symbols[day - 1]
    }
}
