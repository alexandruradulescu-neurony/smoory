import Foundation
import SwiftData

@Model
final class FeedItem {
    var id: UUID = UUID()
    var kind: FeedItemKind = FeedItemKind.alert
    var priority: Double = 0.0
    var pinned: Bool = false
    var headline: String = ""
    var body: String = ""
    var proposedActions: [ProposedAction] = []
    var relatedEntities: [EntityReference] = []
    var confirmationTier: ConfirmationTier = ConfirmationTier.tier1Quick
    var state: FeedItemState = FeedItemState.active
    var dueAt: Date?
    var actedUponAt: Date?
    var dismissedAt: Date?
    var archivedAt: Date?
    var provenance: FeedItemProvenance?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init() {}
}
