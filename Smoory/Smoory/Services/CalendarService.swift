import EventKit
import Foundation
import WidgetKit

struct CalendarEvent: Identifiable, Hashable, Sendable {
    let id: String              // EKEvent.eventIdentifier
    let title: String
    let start: Date
    let end: Date
    let location: String?
    let calendarName: String
    let isAllDay: Bool
}

struct CalendarWindow: Sendable, Hashable {
    struct Day: Sendable, Hashable, Identifiable {
        let date: Date              // start-of-day in Calendar.current
        let events: [CalendarEvent] // sorted by start time
        var id: Date { date }
    }
    let days: [Day]
}

enum CalendarServiceError: Error {
    case accessDenied
    case accessRestricted
    case writeOnlyAccess
    case unknown(Error)
}

@MainActor
final class CalendarService {
    /// Centralizes the AppStorage keys this service reads, so the Settings VM and
    /// the service agree on the storage location without one importing the other.
    enum DefaultsKey {
        static let writableCalendarID = "calendar.writableCalendarID"
        static let excludedCalendarIDs = "calendar.excludedCalendarIDs"
    }

    // Heuristic starting points — tune after living with the behavior.
    private static let secondDayThresholdHour = 12   // before noon → today only
    private static let thirdDayThresholdHour = 15    // 12:00–15:00 → +tomorrow; 15:00+ → +day-after-tomorrow
    /// Events spanning at least this many days are shown only on their first day in the window
    /// with a "through DATE" suffix instead of being duplicated into every day.
    static let multiDayDuplicationThreshold = 3

    private let store = EKEventStore()

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Idempotent. Prompts on .notDetermined, throws on denied/restricted/writeOnly.
    func ensureAccess() async throws {
        switch authorizationStatus {
        case .fullAccess:
            return
        case .writeOnly:
            throw CalendarServiceError.writeOnlyAccess
        case .denied:
            throw CalendarServiceError.accessDenied
        case .restricted:
            throw CalendarServiceError.accessRestricted
        case .notDetermined:
            do {
                let granted = try await store.requestFullAccessToEvents()
                if !granted {
                    throw CalendarServiceError.accessDenied
                }
            } catch let err as CalendarServiceError {
                throw err
            } catch {
                throw CalendarServiceError.unknown(error)
            }
        @unknown default:
            throw CalendarServiceError.accessDenied
        }
    }

    /// Events covering the rolling window relative to `now`:
    ///  - hour < 12       → today only
    ///  - 12 ≤ hour < 15  → today + tomorrow
    ///  - hour ≥ 15       → today + tomorrow + day-after-tomorrow
    /// Returns one Day entry per day in the window even if it has no events.
    func eventsForCurrentWindow(now: Date = Date()) async throws -> CalendarWindow {
        try await ensureAccess()
        let cal = Calendar.current
        let windowStart = cal.startOfDay(for: now)
        let dayCount = Self.windowDayCount(for: now, calendar: cal)
        guard let windowEnd = cal.date(byAdding: .day, value: dayCount, to: windowStart) else {
            return CalendarWindow(days: [])
        }

        let allCalendars = store.calendars(for: .event)
        let excludedIDs = Self.readExcludedCalendarIDs()
        let included = allCalendars.filter { !excludedIDs.contains($0.calendarIdentifier) }
        let predicate = store.predicateForEvents(
            withStart: windowStart,
            end: windowEnd,
            calendars: included.isEmpty ? nil : included   // nil = all calendars
        )
        let events = store.events(matching: predicate).map(Self.toCalendarEvent)

        var days: [CalendarWindow.Day] = []
        for offset in 0..<dayCount {
            guard
                let dayStart = cal.date(byAdding: .day, value: offset, to: windowStart),
                let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)
            else { continue }

            var dayEvents: [CalendarEvent] = []
            for event in events {
                // intersects-day rule: event covers D iff start < startOfDay(D+1) AND end > startOfDay(D)
                guard event.start < dayEnd, event.end > dayStart else { continue }

                let span = Self.daySpan(of: event, calendar: cal)
                if span >= Self.multiDayDuplicationThreshold {
                    // Show only on the first day in the window the event covers.
                    let firstCoveredDayStart = max(cal.startOfDay(for: event.start), windowStart)
                    if cal.isDate(firstCoveredDayStart, inSameDayAs: dayStart) {
                        dayEvents.append(event)
                    }
                } else {
                    dayEvents.append(event)
                }
            }
            dayEvents.sort { $0.start < $1.start }
            days.append(CalendarWindow.Day(date: dayStart, events: dayEvents))
        }

        return CalendarWindow(days: days)
    }

    private static func windowDayCount(for now: Date, calendar: Calendar) -> Int {
        let hour = calendar.component(.hour, from: now)
        if hour < secondDayThresholdHour { return 1 }
        if hour < thirdDayThresholdHour { return 2 }
        return 3
    }

    /// Number of distinct local-calendar days the event covers (inclusive).
    /// A 09:00–10:30 event = 1 day. May 1 → May 3 all-day = 3 days.
    static func daySpan(of event: CalendarEvent, calendar: Calendar) -> Int {
        let firstDay = calendar.startOfDay(for: event.start)
        // Treat endDate exactly at midnight as exclusive — pull back 1 second.
        let lastInstant = (event.end > event.start)
            ? event.end.addingTimeInterval(-1)
            : event.start
        let lastDay = calendar.startOfDay(for: lastInstant)
        let nights = calendar.dateComponents([.day], from: firstDay, to: lastDay).day ?? 0
        return max(1, nights + 1)
    }

    /// Last day (start-of-day) the event covers in the local calendar.
    static func lastCoveredDay(of event: CalendarEvent, calendar: Calendar) -> Date {
        let lastInstant = (event.end > event.start)
            ? event.end.addingTimeInterval(-1)
            : event.start
        return calendar.startOfDay(for: lastInstant)
    }

    /// Refreshes today's calendar events and writes the live snapshot the desktop
    /// widget reads. Best-effort: failures (calendar permission denied, container
    /// unavailable) are logged and swallowed. Calls WidgetCenter.reloadAllTimelines
    /// on success so the widget renders the new state on its next provider invocation.
    func refreshAndWriteSnapshot(writer: AppGroupContainerWriter? = nil) async {
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        do {
            let window = try await eventsForCurrentWindow(now: now)
            let todayEvents = window.days
                .first(where: { cal.isDate($0.date, inSameDayAs: startOfToday) })
                .map { $0.events } ?? []
            let entries = todayEvents.map { ev in
                CalendarSnapshot.CalendarEventEntry(
                    title: ev.title,
                    startTime: ev.start,
                    endTime: ev.end,
                    isAllDay: ev.isAllDay,
                    location: ev.location
                )
            }
            let snapshot = CalendarSnapshot(
                updatedAt: now,
                forDate: startOfToday,
                events: entries
            )
            (writer ?? AppGroupContainerWriter())?.writeCalendarSnapshot(snapshot)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            print("[calendar] snapshot refresh failed: \(error)")
        }
    }

    /// All calendars EventKit knows about that the user can read events from.
    /// Subscribed read-only calendars are included — they're useful for the read
    /// filter even though they can't be written to.
    func listAvailableCalendars() -> [EKCalendar] {
        store.calendars(for: .event).sorted { $0.title < $1.title }
    }

    /// Calendars the user can write events to. Filters out subscribed/read-only
    /// calendars so the Settings picker only offers valid write targets.
    func listWritableCalendars() -> [EKCalendar] {
        store.calendars(for: .event)
            .filter { $0.allowsContentModifications }
            .sorted { $0.title < $1.title }
    }

    /// Resolves the configured "Smoory writes here" calendar. Falls back to the
    /// system default. Returns nil only if the user has zero writable calendars.
    func writableCalendar() -> EKCalendar? {
        let configuredID = UserDefaults.standard.string(forKey: DefaultsKey.writableCalendarID)
        if let configuredID, !configuredID.isEmpty,
           let match = store.calendar(withIdentifier: configuredID),
           match.allowsContentModifications {
            return match
        }
        return store.defaultCalendarForNewEvents
    }

    /// Returns events overlapping `start..<end` from non-excluded calendars,
    /// optionally skipping a specific event id (used by `move_calendar_event`
    /// so the event being moved isn't reported as overlapping itself).
    func findConflicts(
        start: Date,
        end: Date,
        excludingEventID: String? = nil
    ) async throws -> [CalendarEvent] {
        try await ensureAccess()
        let allCalendars = store.calendars(for: .event)
        let excludedIDs = Self.readExcludedCalendarIDs()
        let included = allCalendars.filter { !excludedIDs.contains($0.calendarIdentifier) }
        let predicate = store.predicateForEvents(
            withStart: start,
            end: end,
            calendars: included.isEmpty ? nil : included
        )
        let raw = store.events(matching: predicate)
        return raw
            .filter { event in
                // The predicate is inclusive on both ends; trim equal-edge events
                // (a 14:00–15:00 event isn't a conflict for a 15:00–16:00 block).
                event.startDate < end && event.endDate > start
            }
            .filter { $0.eventIdentifier != excludingEventID }
            .map(Self.toCalendarEvent)
            .sorted { $0.start < $1.start }
    }

    private static func toCalendarEvent(_ ek: EKEvent) -> CalendarEvent {
        let location = ek.location.flatMap { $0.isEmpty ? nil : $0 }
        return CalendarEvent(
            id: ek.eventIdentifier ?? UUID().uuidString,
            title: ek.title ?? "",
            start: ek.startDate,
            end: ek.endDate,
            location: location,
            calendarName: ek.calendar.title,
            isAllDay: ek.isAllDay
        )
    }

    private static func readExcludedCalendarIDs() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.excludedCalendarIDs),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(array)
    }
}
