import Foundation

/// Per-event status the widget computes at render time using `entry.date`.
/// Widget redraws on the WidgetKit timeline cadence (15 min today) plus
/// `WidgetCenter.reloadAllTimelines()` calls from the main app — so any
/// individual event's transition between `.upcoming → .happening → .completed`
/// becomes visible on the next provider invocation.
enum CalendarEventStatus: Sendable {
    case completed     // endTime <= now
    case happening     // startTime <= now < endTime
    case upcoming      // startTime > now
}

extension WidgetCalendarEvent {
    func status(now: Date) -> CalendarEventStatus {
        if endTime <= now { return .completed }
        if startTime <= now { return .happening }
        return .upcoming
    }
}

extension Array where Element == WidgetCalendarEvent {
    /// Picks the single event most relevant to "right now" for the medium
    /// widget's one calendar row:
    ///   1. Active event (happening) wins.
    ///   2. Else next upcoming.
    ///   3. Else a recently-ended event (within 30 min of `now`) so the user
    ///      sees "Just wrapped: X" briefly after a meeting closes.
    /// Returns nil when none of the above apply (day's clear).
    func nowOrNext(at now: Date) -> WidgetCalendarEvent? {
        if let active = first(where: { $0.startTime <= now && $0.endTime > now }) {
            return active
        }
        let upcoming = filter { $0.startTime > now }.sorted { $0.startTime < $1.startTime }
        if let next = upcoming.first {
            return next
        }
        let recentlyEnded = filter {
            $0.endTime <= now && now.timeIntervalSince($0.endTime) <= 30 * 60
        }.sorted { $0.endTime > $1.endTime }
        return recentlyEnded.first
    }
}
