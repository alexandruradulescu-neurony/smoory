import Foundation

enum Cadence: Int, Codable, Sendable {
    case daily = 0
    case weekly = 1
    case biweekly = 2
    case monthly = 3
    case quarterly = 4
}

enum Weekday: Int, Codable, Sendable {
    case sunday = 0
    case monday = 1
    case tuesday = 2
    case wednesday = 3
    case thursday = 4
    case friday = 5
    case saturday = 6
}

struct TimeOfDay: Hashable, Sendable {
    var hour: Int = 0
    var minute: Int = 0
}

extension TimeOfDay: Codable {}
