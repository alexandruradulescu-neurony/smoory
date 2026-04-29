import Foundation

enum CaptureKind: Int, Codable, Sendable {
    case text = 0
    case url = 1
    case file = 2
    case image = 3
    case voiceNote = 4
    case pdf = 5
}

enum CaptureSource: Int, Codable, Sendable {
    case chatDropped = 0
    case shareExtension = 1
    case quickAdd = 2
    case smooryInferred = 3
}

enum CaptureLinkEntityType: Int, Codable, Sendable {
    case role = 0
    case goal = 1
    case project = 2
    case thread = 3
    case todo = 4
    case habit = 5
    case person = 6
    case infrastructure = 7
}

struct CaptureLink: Hashable, Sendable {
    var entityType: CaptureLinkEntityType
    var entityId: UUID
    var linkReason: String?
}

extension CaptureLink: Codable {}
