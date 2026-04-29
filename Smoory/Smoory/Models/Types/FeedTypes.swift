import Foundation

enum FeedItemKind: Int, Codable, Sendable {
    case emailAnnotation = 0
    case todoProposal = 1
    case calendarNudge = 2
    case morningBrief = 3
    case dayReview = 4
    case weekReview = 5
    case alert = 6
    case memoryCandidate = 7
    case goalCandidate = 8
    case personCandidate = 9
    case threadProposal = 10
    case patternObservation = 11
    case checkInDue = 12
}

enum ConfirmationTier: Int, Codable, Sendable {
    case tier1Quick = 0
    case tier2Review = 1
    case tier3Dialog = 2
    case silent = 3
}

enum FeedItemState: Int, Codable, Sendable {
    case active = 0
    case actedUpon = 1
    case dismissed = 2
    case deferred = 3
}

struct ProposedAction: Hashable, Sendable {
    var toolName: String
    var parametersJSON: String         // heterogeneous per tool — see DECISIONS.md decision 5
    var confirmationTier: ConfirmationTier
    var preview: String
}

extension ProposedAction: Codable {}

enum EntityKind: Int, Codable, Sendable {
    case role = 0
    case goal = 1
    case project = 2
    case thread = 3
    case todo = 4
    case habit = 5
    case person = 6
    case profile = 7
    case infrastructure = 8
    case captureItem = 9
    case feedItem = 10
    case chatMessage = 11
}

struct EntityReference: Hashable, Sendable {
    var entityKind: EntityKind
    var entityId: UUID
    var displayLabel: String?
}

extension EntityReference: Codable {}

struct FeedItemProvenance: Hashable, Sendable {
    var loopId: UUID
    var sensorKind: String
    var callType: String
    var modelUsed: String?
    var elapsedMs: Int?
}

extension FeedItemProvenance: Codable {}
