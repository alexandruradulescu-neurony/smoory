import Foundation

struct WorkingHours: Hashable, Sendable {
    struct Range: Hashable, Sendable {
        var weekday: Weekday
        var start: TimeOfDay
        var end: TimeOfDay
    }
    var ranges: [Range] = []
}

extension WorkingHours: Codable {}
extension WorkingHours.Range: Codable {}
