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
    /// F-1 audit fix: SwiftData's `#Predicate` can't access enum `.rawValue` and direct
    /// enum comparison on `FeedItemState` crashed the validator, so the FeedView's query
    /// previously fetched everything and filtered client-side. `stateRaw` mirrors the
    /// pattern used by `kindRaw` elsewhere in the schema and lets `@Query` filter at
    /// the SQLite layer. The `state` accessor below stays as the public API so
    /// callers don't need to touch the raw int.
    var stateRaw: Int = FeedItemState.active.rawValue
    var dueAt: Date?
    var actedUponAt: Date?
    var dismissedAt: Date?
    var archivedAt: Date?
    var provenance: FeedItemProvenance?
    var payloadJSON: String?            // structured kind-specific payload (e.g., MorningBrief JSON)
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init() {}

    /// Computed accessor over `stateRaw` so existing callsites continue to work.
    var state: FeedItemState {
        get { FeedItemState(rawValue: stateRaw) ?? .active }
        set { stateRaw = newValue.rawValue }
    }
}
