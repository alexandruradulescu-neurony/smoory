import Foundation
import Observation
import SwiftData

/// View model for the Settings → Day review section. Source of truth is the existing
/// pending recurring ScheduledAction row (if any); the picker is initialized from its
/// recurringRule.timeOfDay. UserDefaults is NOT used — the SwiftData row IS the state.
///
/// Picker default when no row exists: 21:00 (per 3.2 proposal discovery).
@Observable
@MainActor
final class DayReviewSettingsViewModel {
    var dayReviewEnabled: Bool = false {
        didSet { applyChanges() }
    }
    var dayReviewTime: Date {
        didSet { applyChanges() }
    }

    private let modelContainer: ModelContainer
    private let service: ScheduledActionService?
    /// Suppresses applyChanges while the view model is loading state from disk.
    private var isLoading: Bool = false
    private var debounceTask: Task<Void, Never>?

    init(modelContainer: ModelContainer, service: ScheduledActionService?) {
        self.modelContainer = modelContainer
        self.service = service
        self.dayReviewTime = Self.defaultPickerTime()
        loadCurrentState()
    }

    private func loadCurrentState() {
        isLoading = true
        defer { isLoading = false }

        guard let row = currentRecurringDayReview() else {
            dayReviewEnabled = false
            dayReviewTime = Self.defaultPickerTime()
            return
        }
        dayReviewEnabled = true
        dayReviewTime = Self.dateFromTimeOfDay(row.recurringRule?.timeOfDay) ?? row.scheduledFor
    }

    private func applyChanges() {
        guard !isLoading else { return }
        debounceTask?.cancel()
        let snapshotEnabled = dayReviewEnabled
        let snapshotTime = dayReviewTime
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            await reconcile(enabled: snapshotEnabled, time: snapshotTime)
        }
    }

    private func reconcile(enabled: Bool, time: Date) async {
        guard let service else {
            print("[settings] ScheduledActionService unavailable; cannot reconcile day review")
            return
        }

        let existing = currentRecurringDayReview()

        switch (enabled, existing) {
        case (false, nil):
            return
        case (false, let row?):
            try? await service.cancel(actionID: row.id)
        case (true, nil):
            // Create a new daily-recurring row at the picker time.
            let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
            let firstFire = Self.nextFire(at: comps, after: Date())
            let rule = RecurringRule(kind: .daily, timeOfDay: comps, dayOfWeek: nil)
            do {
                _ = try await service.schedule(
                    kind: .dayReview,
                    at: firstFire,
                    content: "",
                    recurringRule: rule,
                    relatedEntityID: nil,
                    source: .system
                )
            } catch {
                print("[settings] failed to schedule day review: \(error)")
            }
        case (true, let row?):
            // Update time on the existing row. Cancel + recreate keeps the rule and the
            // notification request consistent; ScheduledActionService doesn't expose a
            // "mutate recurringRule + reschedule" composite, so we go through the door
            // we have: cancel kills the recurring thread, schedule starts a new one.
            try? await service.cancel(actionID: row.id)
            let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
            let firstFire = Self.nextFire(at: comps, after: Date())
            let rule = RecurringRule(kind: .daily, timeOfDay: comps, dayOfWeek: nil)
            do {
                _ = try await service.schedule(
                    kind: .dayReview,
                    at: firstFire,
                    content: "",
                    recurringRule: rule,
                    relatedEntityID: nil,
                    source: .system
                )
            } catch {
                print("[settings] failed to reschedule day review: \(error)")
            }
        }
    }

    private func currentRecurringDayReview() -> ScheduledAction? {
        let context = ModelContext(modelContainer)
        let pendingRaw = ScheduledActionStatus.pending.rawValue
        let dayReviewRaw = ScheduledActionKind.dayReview.rawValue
        let descriptor = FetchDescriptor<ScheduledAction>(
            predicate: #Predicate { $0.kindRaw == dayReviewRaw && $0.statusRaw == pendingRaw },
            sortBy: [SortDescriptor(\.scheduledFor, order: .forward)]
        )
        return (try? context.fetch(descriptor))?.first { $0.recurringRuleJSON != nil }
    }

    // MARK: - Static helpers

    private static func defaultPickerTime() -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 21
        comps.minute = 0
        return Calendar.current.date(from: comps) ?? Date()
    }

    private static func dateFromTimeOfDay(_ tod: DateComponents?) -> Date? {
        guard let tod, let hour = tod.hour, let minute = tod.minute else { return nil }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        return Calendar.current.date(from: comps)
    }

    /// Next occurrence of HH:MM strictly after `now` (today if HH:MM hasn't passed,
    /// tomorrow otherwise).
    private static func nextFire(at hourMinute: DateComponents, after now: Date) -> Date {
        let cal = Calendar.current
        var todayComps = cal.dateComponents([.year, .month, .day], from: now)
        todayComps.hour = hourMinute.hour
        todayComps.minute = hourMinute.minute
        todayComps.second = 0
        let candidate = cal.date(from: todayComps) ?? now
        return candidate > now ? candidate : (cal.date(byAdding: .day, value: 1, to: candidate) ?? candidate)
    }
}
