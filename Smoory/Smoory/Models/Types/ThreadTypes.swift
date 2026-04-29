import Foundation

enum ThreadStatus: Int, Codable, Sendable {
    case open = 0
    case active = 1
    case awaiting = 2
    case closed = 3
}

struct EmailReference: Hashable, Sendable {
    var messageId: String              // Apple Mail message-ID
    var internetMessageId: String?     // RFC 822 Message-ID header
    var receivedAt: Date
}

extension EmailReference: Codable {}

enum ThreadEventKind: Int, Codable, Sendable {
    case emailArrived = 0
    case emailSent = 1
    case todoCreated = 2
    case todoCompleted = 3
    case statusChanged = 4
    case draftSent = 5
    case noteAdded = 6
}

struct ThreadEvent: Hashable, Sendable {
    var timestamp: Date
    var kind: ThreadEventKind
    var summary: String
}

extension ThreadEvent: Codable {}
