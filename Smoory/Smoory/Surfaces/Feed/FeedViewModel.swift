import Foundation
import Observation

enum FeedTypeFilter: Hashable, CaseIterable, Identifiable {
    case all, goals, todos, facts, people, projects, infrastructure, availability, toneObservations
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "All types"
        case .goals: "Goals"
        case .todos: "Todos"
        case .facts: "Facts"
        case .people: "People"
        case .projects: "Projects"
        case .infrastructure: "Infrastructure"
        case .availability: "Availability"
        case .toneObservations: "Tone"
        }
    }

    func matches(_ type: CandidateType) -> Bool {
        switch self {
        case .all: return true
        case .goals: return type == .goal
        case .todos: return type == .todo
        case .facts: return type == .fact
        case .people: return type == .person
        case .projects: return type == .project
        case .infrastructure: return type == .infrastructure
        case .availability: return type == .availability
        case .toneObservations: return type == .toneObservation
        }
    }
}

enum FeedStatusFilter: Hashable, CaseIterable, Identifiable {
    case pending, confirmed, rejected
    var id: Self { self }
    var title: String {
        switch self {
        case .pending: "Pending"
        case .confirmed: "Confirmed"
        case .rejected: "Rejected"
        }
    }
}

@Observable
@MainActor
final class FeedViewModel {
    var searchText: String = ""
    var typeFilter: FeedTypeFilter = .all
    var statusFilter: FeedStatusFilter = .pending

    /// Combined sorted list of candidate + feed item rows. Sort: priority/confidence DESC,
    /// then createdAt DESC. Search and type-filter applied client-side.
    func compose(
        candidates: [CandidateWrite],
        feedItems: [FeedItem]
    ) -> [FeedRow] {
        let typeFiltered = candidates.filter { typeFilter.matches($0.type) }

        let searchedCandidates: [CandidateWrite] = {
            guard !searchText.isEmpty else { return typeFiltered }
            let q = searchText.lowercased()
            return typeFiltered.filter {
                $0.effectiveContent.lowercased().contains(q)
                    || $0.userPhrase.lowercased().contains(q)
            }
        }()

        // Defensive dedup: morning briefs are 1-per-day; if multiple show up as
        // active simultaneously (e.g. data migrated from a pre-stateRaw schema
        // where `state = .actedUpon` was lost in the schema change), keep only
        // the freshest. The cleanup task in FeedView writes the rest back to
        // .actedUpon so the next render sees a single canonical row.
        let dedupedItems = Self.keepingLatestMorningBrief(feedItems)

        let searchedItems: [FeedItem] = {
            guard !searchText.isEmpty else { return dedupedItems }
            let q = searchText.lowercased()
            return dedupedItems.filter {
                $0.headline.lowercased().contains(q)
                    || $0.body.lowercased().contains(q)
            }
        }()

        var rows: [FeedRow] = []
        rows.append(contentsOf: searchedCandidates.map(FeedRow.candidate))
        rows.append(contentsOf: searchedItems.map(FeedRow.feedItem))
        return rows.sorted { lhs, rhs in
            let l = lhs.sortKey
            let r = rhs.sortKey
            if l.0 != r.0 { return l.0 > r.0 }
            return l.1 > r.1
        }
    }

    /// Returns `items` with all but the most-recent morningBrief filtered out.
    /// Other kinds pass through unchanged.
    private static func keepingLatestMorningBrief(_ items: [FeedItem]) -> [FeedItem] {
        let briefs = items.filter { $0.kind == .morningBrief }
        guard briefs.count > 1 else { return items }
        let newestID = briefs.max(by: { $0.createdAt < $1.createdAt })?.id
        return items.filter { item in
            item.kind != .morningBrief || item.id == newestID
        }
    }

    var hasActiveFilters: Bool {
        typeFilter != .all || statusFilter != .pending || !searchText.isEmpty
    }
}
