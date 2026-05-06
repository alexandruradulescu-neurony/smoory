import EventKit
import Foundation
import Observation
import SwiftUI

/// Drives the Calendar section in Settings. Eagerly init via
/// `_vm = State(wrappedValue:)` (matches ReviewScheduleSettings F-17 fix) so the
/// section paints fully populated on the first frame.
@Observable
@MainActor
final class CalendarSettingsViewModel {
    /// All calendars EventKit knows about, sorted by title. Refreshed on init and
    /// whenever the system fires `EKEventStoreChanged`.
    private(set) var availableCalendars: [EKCalendar] = []
    /// Subset of `availableCalendars` the user can write to (filters out
    /// subscribed/read-only). Drives the "Smoory writes here" picker.
    private(set) var writableCalendars: [EKCalendar] = []

    /// Configured writable calendar id. Empty string == "use system default".
    var writableCalendarID: String {
        didSet { UserDefaults.standard.set(writableCalendarID, forKey: CalendarService.DefaultsKey.writableCalendarID) }
    }

    /// Per-calendar excluded set. Toggle binding writes through this.
    var excludedCalendarIDs: Set<String> {
        didSet { persistExcluded() }
    }

    private let calendarService: CalendarService
    // nonisolated(unsafe) lets deinit (which is nonisolated) cancel the task
    // without triggering the main-actor isolation error.
    nonisolated(unsafe) private var observationTask: Task<Void, Never>?

    init(calendarService: CalendarService) {
        self.calendarService = calendarService
        self.writableCalendarID = UserDefaults.standard.string(forKey: CalendarService.DefaultsKey.writableCalendarID) ?? ""
        if let data = UserDefaults.standard.data(forKey: CalendarService.DefaultsKey.excludedCalendarIDs),
           let array = try? JSONDecoder().decode([String].self, from: data) {
            self.excludedCalendarIDs = Set(array)
        } else {
            self.excludedCalendarIDs = []
        }
        refresh()
        startObservingStoreChanges()
    }

    deinit {
        observationTask?.cancel()
    }

    func refresh() {
        availableCalendars = calendarService.listAvailableCalendars()
        writableCalendars = calendarService.listWritableCalendars()
    }

    /// True when the calendar's events should appear in Feed / brief / reviews.
    func isIncluded(_ calendar: EKCalendar) -> Bool {
        !excludedCalendarIDs.contains(calendar.calendarIdentifier)
    }

    /// Two-way binding for the per-calendar toggle row.
    func includedBinding(for calendar: EKCalendar) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.isIncluded(calendar) ?? true },
            set: { [weak self] newValue in
                guard let self else { return }
                if newValue {
                    self.excludedCalendarIDs.remove(calendar.calendarIdentifier)
                } else {
                    self.excludedCalendarIDs.insert(calendar.calendarIdentifier)
                }
            }
        )
    }

    private func persistExcluded() {
        let array = Array(excludedCalendarIDs).sorted()
        if let data = try? JSONEncoder().encode(array) {
            UserDefaults.standard.set(data, forKey: CalendarService.DefaultsKey.excludedCalendarIDs)
        }
    }

    private func startObservingStoreChanges() {
        observationTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                guard let self else { return }
                self.refresh()
            }
        }
    }
}
