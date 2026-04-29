import Foundation

enum TodoPriority: Int, Codable, Sendable {
    case low = 0
    case normal = 1
    case high = 2
    case urgent = 3
}

enum TodoSource: Int, Codable, Sendable {
    case userChat = 0
    case userQuickadd = 1
    case aiProposal = 2
    case emailExtraction = 3
    case calendarExtraction = 4
    case manual = 5
}
