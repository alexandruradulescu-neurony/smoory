import Foundation

enum GoalType: Int, Codable, Sendable {
    case tracked = 0
    case reflective = 1
    case both = 2
}

enum GoalStatus: Int, Codable, Sendable {
    case active = 0
    case paused = 1
    case achieved = 2
    case dropped = 3
}

enum TrackedMetric: Int, Codable, Sendable {
    case pagesRead = 0
    case sessionsCompleted = 1
    case todosUnderProject = 2
    case minutesLogged = 3
    case custom = 4
}

struct TrackedSignal: Hashable, Sendable {
    var metric: TrackedMetric
    var target: Double
    var cadence: Cadence
    var unit: String
}

extension TrackedSignal: Codable {}

struct ReflectiveCadence: Hashable, Sendable {
    var frequency: Cadence
    var preferredDay: Weekday?
    var preferredQuestion: String?
}

extension ReflectiveCadence: Codable {}
