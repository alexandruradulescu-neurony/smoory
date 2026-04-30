import Foundation

/// Unified row type for the Feed surface. 2.5 currently surfaces only candidates.
/// FeedItem support is stubbed for forward compatibility — Phase 3 producers will
/// generate FeedItem rows for briefs, reviews, alerts, etc.
enum FeedRow: Identifiable, Hashable {
    case candidate(CandidateWrite)
    case feedItem(FeedItem)

    var id: UUID {
        switch self {
        case .candidate(let c): return c.id
        case .feedItem(let f): return f.id
        }
    }

    var sortKey: (Double, Date) {
        switch self {
        case .candidate(let c): return (c.confidence, c.createdAt)
        case .feedItem(let f): return (f.priority, f.createdAt)
        }
    }
}
