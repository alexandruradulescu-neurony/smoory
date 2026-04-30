import AppKit
import Foundation
import Observation

/// Loads the rolling calendar window and exposes per-day sections to FeedView.
/// State machine mirrors milestone 1.5's FeedViewModel.State so denied/restricted
/// access surfaces the same recovery affordances.
@Observable
@MainActor
final class FeedCalendarLoader {
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
            let trailingSuffix: String?     // e.g. "(through May 3)" for multi-day events
            var id: String { event.id + (trailingSuffix ?? "") }
        }
        let date: Date
        let header: String
        let allDay: [Item]
        let timed: [Item]
        var id: Date { date }
        var isEmpty: Bool { allDay.isEmpty && timed.isEmpty }
    }

    private(set) var state: State = .loading

    private let calendar: CalendarService

    init(calendar: CalendarService? = nil) {
        // CalendarService is @MainActor — construct lazily inside this @MainActor init
        // so the default arg doesn't pin the synthesized init to the wrong actor.
        self.calendar = calendar ?? CalendarService()
    }

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
            state = .error("Smoory has write-only calendar access. Grant full access in System Settings to read events.")
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    func openCalendarPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Returns the sections filtered by `query` (case-insensitive substring match against
    /// event title and location). Empty query returns sections unchanged. Empty days are
    /// removed from the result when query is non-empty so the surface doesn't surface
    /// empty "Today" sections during search.
    static func filtered(_ sections: [DaySection], query: String) -> [DaySection] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return sections }
        let needle = trimmed.lowercased()
        return sections.compactMap { section in
            let allDay = section.allDay.filter { Self.matches($0.event, needle: needle) }
            let timed = section.timed.filter { Self.matches($0.event, needle: needle) }
            if allDay.isEmpty && timed.isEmpty { return nil }
            return DaySection(date: section.date, header: section.header, allDay: allDay, timed: timed)
        }
    }

    private static func matches(_ event: CalendarEvent, needle: String) -> Bool {
        if event.title.lowercased().contains(needle) { return true }
        if let loc = event.location, loc.lowercased().contains(needle) { return true }
        return false
    }

    // MARK: - Section building

    private static func makeSections(from window: CalendarWindow) -> [DaySection] {
        let cal = Calendar.current
        return window.days.map { day in
            let allDay = day.events.filter(\.isAllDay).map { Self.makeItem(for: $0, calendar: cal) }
            let timed = day.events.filter { !$0.isAllDay }.map { Self.makeItem(for: $0, calendar: cal) }
            return DaySection(
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
