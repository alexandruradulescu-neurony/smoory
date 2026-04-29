import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class FeedViewModel {
    enum State {
        case loading
        case ready(sections: [DaySection])
        case denied
        case restricted
        case error(String)
    }

    struct DaySection: Identifiable, Hashable {
        struct Item: Identifiable, Hashable {
            let event: CalendarEvent
            let trailingSuffix: String?     // e.g. "(through May 3)" — only set on multi-day events shown on a single day
            var id: String { event.id + (trailingSuffix ?? "") }
        }
        let id: Date
        let date: Date
        let header: String
        let allDay: [Item]
        let timed: [Item]
        var isEmpty: Bool { allDay.isEmpty && timed.isEmpty }
    }

    private(set) var state: State = .loading

    private let calendar = CalendarService()

    func load() async {
        state = .loading
        do {
            let window = try await calendar.eventsForCurrentWindow()
            state = .ready(sections: Self.makeSections(from: window))
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
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Section building

    private static func makeSections(from window: CalendarWindow) -> [DaySection] {
        let cal = Calendar.current
        return window.days.map { day in
            let allDay = day.events.filter(\.isAllDay).map { Self.makeItem(for: $0, calendar: cal) }
            let timed = day.events.filter { !$0.isAllDay }.map { Self.makeItem(for: $0, calendar: cal) }
            return DaySection(
                id: day.date,
                date: day.date,
                header: Self.makeHeader(for: day.date, calendar: cal),
                allDay: allDay,
                timed: timed
            )
        }
    }

    private static func makeItem(for event: CalendarEvent, calendar: Calendar) -> DaySection.Item {
        let span = CalendarService.daySpan(of: event, calendar: calendar)
        guard span >= CalendarService.multiDayDuplicationThreshold else {
            return DaySection.Item(event: event, trailingSuffix: nil)
        }
        let lastDay = CalendarService.lastCoveredDay(of: event, calendar: calendar)
        let formatted = lastDay.formatted(.dateTime.month().day())
        return DaySection.Item(event: event, trailingSuffix: "(through \(formatted))")
    }

    private static func makeHeader(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.wide).month().day())
    }
}
