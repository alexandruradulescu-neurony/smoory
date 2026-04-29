import Foundation
import SwiftData

@Model
final class Schedule {
    var id: UUID = UUID()
    var kind: ScheduleKind = ScheduleKind.morningBrief
    var time: TimeOfDay = TimeOfDay(hour: 8, minute: 0)
    var daysOfWeek: [Weekday] = []
    var notify: Bool = false
    var enabled: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init() {}
}
