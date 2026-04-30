import Foundation
import Observation
import SwiftData

/// Mirrors DayReviewSettingsViewModel — single source of truth is the existing pending
/// recurring ScheduledAction row. Picker default 7:00 AM when no row exists.
@Observable
@MainActor
final class MorningBriefSettingsViewModel {
    var morningBriefEnabled: Bool = false {
        didSet { applyChanges() }
    }
    var morningBriefTime: Date {
        didSet { applyChanges() }
    }

    private let modelContainer: ModelContainer
    private let service: ScheduledActionService?
    private var isLoading: Bool = false
    private var debounceTask: Task<Void, Never>?

    init(modelContainer: ModelContainer, service: ScheduledActionService?) {
        self.modelContainer = modelContainer
        self.service = service
        self.morningBriefTime = Self.defaultPickerTime()
        loadCurrentState()
    }

    private func loadCurrentState() {
        isLoading = true
        defer { isLoading = false }
        guard let row = currentRecurringMorningBrief() else {
            morningBriefEnabled = false
            morningBriefTime = Self.defaultPickerTime()
            return
        }
        morningBriefEnabled = true
        morningBriefTime = Self.dateFromTimeOfDay(row.recurringRule?.timeOfDay) ?? row.scheduledFor
    }

    private func applyChanges() {
        guard !isLoading else { return }
        debounceTask?.cancel()
        let snapshotEnabled = morningBriefEnabled
        let snapshotTime = morningBriefTime
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            await reconcile(enabled: snapshotEnabled, time: snapshotTime)
        }
    }

    private func reconcile(enabled: Bool, time: Date) async {
        guard let service else {
            print("[settings] ScheduledActionService unavailable; cannot reconcile morning brief")
            return
        }
        let existing = currentRecurringMorningBrief()
        switch (enabled, existing) {
        case (false, nil):
            return
        case (false, let row?):
            try? await service.cancel(actionID: row.id)
        case (true, nil):
            await scheduleNew(time: time, service: service)
        case (true, let row?):
            try? await service.cancel(actionID: row.id)
            await scheduleNew(time: time, service: service)
        }
    }

    private func scheduleNew(time: Date, service: ScheduledActionService) async {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        let firstFire = Self.nextFire(at: comps, after: Date())
        let rule = RecurringRule(kind: .daily, timeOfDay: comps, dayOfWeek: nil)
        do {
            _ = try await service.schedule(
                kind: .morningBrief,
                at: firstFire,
                content: "",
                recurringRule: rule,
                relatedEntityID: nil,
                source: .system
            )
        } catch {
            print("[settings] failed to schedule morning brief: \(error)")
        }
    }

    private func currentRecurringMorningBrief() -> ScheduledAction? {
        let context = ModelContext(modelContainer)
        let pendingRaw = ScheduledActionStatus.pending.rawValue
        let kindRaw = ScheduledActionKind.morningBrief.rawValue
        let descriptor = FetchDescriptor<ScheduledAction>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.statusRaw == pendingRaw },
            sortBy: [SortDescriptor(\.scheduledFor, order: .forward)]
        )
        return (try? context.fetch(descriptor))?.first { $0.recurringRuleJSON != nil }
    }

    private static func defaultPickerTime() -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = 7
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
