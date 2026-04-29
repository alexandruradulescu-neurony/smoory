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

enum CalendarServiceError: Error {
    case accessDenied
    case accessRestricted
    case writeOnlyAccess
    case unknown(Error)
}

final class CalendarService: @unchecked Sendable {
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

    /// Today's events across all granted calendars, sorted by start time.
    func eventsForToday() async throws -> [CalendarEvent] {
        try await ensureAccess()
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else {
            return []
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
        return events
            .sorted { $0.startDate < $1.startDate }
            .map { ek in
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
}
