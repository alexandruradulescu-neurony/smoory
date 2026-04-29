import Foundation

enum ProjectStatus: Int, Codable, Sendable {
    case planning = 0
    case active = 1
    case paused = 2
    case completed = 3
    case abandoned = 4
}
