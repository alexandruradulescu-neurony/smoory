import Foundation
import WidgetKit

struct BriefEntry: TimelineEntry {
    let date: Date
    let brief: WidgetMorningBrief?
    let briefStaleness: BriefStaleness
    let upcomingActions: [WidgetScheduledAction]
    let calendar: WidgetCalendarSnapshot?
    let todos: WidgetTodosSnapshot?

    static let placeholder = BriefEntry(
        date: Date(),
        brief: WidgetMorningBrief.preview,
        briefStaleness: .today,
        upcomingActions: [],
        calendar: nil,
        todos: nil
    )
}

enum BriefStaleness: String, Codable, Sendable {
    case today
    case yesterday
    case older
    case missing
}
