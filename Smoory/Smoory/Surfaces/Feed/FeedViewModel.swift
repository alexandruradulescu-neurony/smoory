import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class FeedViewModel {
    enum State {
        case loading
        case ready(allDay: [CalendarEvent], timed: [CalendarEvent])
        case denied
        case restricted
        case error(String)
    }

    private(set) var state: State = .loading

    private let calendar = CalendarService()

    func load() async {
        state = .loading
        do {
            let events = try await calendar.eventsForToday()
            let allDay = events.filter { $0.isAllDay }
            let timed = events.filter { !$0.isAllDay }
            state = .ready(allDay: allDay, timed: timed)
        } catch CalendarServiceError.accessDenied {
            state = .denied
        } catch CalendarServiceError.accessRestricted {
            state = .restricted
        } catch CalendarServiceError.writeOnlyAccess {
            state = .error("Smoory has write-only access to your calendar. Grant full access in Settings to read your calendar.")
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func openCalendarPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
