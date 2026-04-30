import EventKit
import Foundation

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

        let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
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
}
