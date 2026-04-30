import Foundation
import Observation

@Observable
@MainActor
final class FactsListViewModel {
    let hema: HemaService

    private(set) var facts: [SemanticFact] = []
    private(set) var isLoading = false
    private(set) var loadError: String?

    var searchText: String = ""
    var selectedTags: Set<String> = []
    var ageFilter: AgeFilter = .all
    var confidenceFilter: ConfidenceFilter = .all
    var confirmationFilter: ConfirmationFilter = .all
    var showPrivate: Bool = false

    enum AgeFilter: Hashable, CaseIterable, Identifiable {
        case all, lastWeek, lastMonth, older
        var id: Self { self }
        var title: String {
            switch self {
            case .all: "Any age"
            case .lastWeek: "Last week"
            case .lastMonth: "Last month"
            case .older: "Older than month"
            }
        }
    }

    enum ConfidenceFilter: Hashable, CaseIterable, Identifiable {
        case all, highConfidence, mediumConfidence, lowConfidence
        var id: Self { self }
        var title: String {
            switch self {
            case .all: "Any confidence"
            case .highConfidence: "High (≥85%)"
            case .mediumConfidence: "Medium (50–85%)"
            case .lowConfidence: "Low (<50%)"
            }
        }
    }

    enum ConfirmationFilter: Hashable, CaseIterable, Identifiable {
        case all, userConfirmed, unconfirmed
        var id: Self { self }
        var title: String {
            switch self {
            case .all: "Any confirmation"
            case .userConfirmed: "User-confirmed"
            case .unconfirmed: "Unconfirmed"
            }
        }
    }

    init(hema: HemaService) {
        self.hema = hema
        Task { await load() }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let filter = currentFactFilter()
            facts = try await hema.readAllFacts(filter: filter, limit: 500, offset: 0)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func deleteFact(id: UUID) async {
        do {
            try await hema.deleteFact(id: id)
            facts.removeAll { $0.id == id }
        } catch {
            loadError = "Delete failed: \(error.localizedDescription)"
        }
    }

    func updateFact(_ fact: SemanticFact) async {
        do {
            try await hema.updateFact(fact)
            if let idx = facts.firstIndex(where: { $0.id == fact.id }) {
                facts[idx] = fact
            }
        } catch {
            loadError = "Update failed: \(error.localizedDescription)"
        }
    }

    /// All unique tags across the loaded fact set, sorted. Drives the tag filter menu.
    var availableTags: [String] {
        Array(Set(facts.flatMap(\.tags))).sorted()
    }

    /// Filters loaded facts client-side for: search text, show-private toggle, confirmation status.
    /// Server-side filter handles age, confidence, tags. Two-layer split lets toggles update
    /// without re-querying hema.
    var displayedFacts: [SemanticFact] {
        var filtered = facts

        if !showPrivate {
            filtered = filtered.filter { !$0.isPrivate }
        }

        switch confirmationFilter {
        case .all: break
        case .userConfirmed: filtered = filtered.filter { $0.userConfirmed }
        case .unconfirmed: filtered = filtered.filter { !$0.userConfirmed }
        }

        if !searchText.isEmpty {
            let q = searchText.lowercased()
            filtered = filtered.filter { fact in
                fact.body.lowercased().contains(q)
                    || fact.tags.contains(where: { $0.lowercased().contains(q) })
            }
        }
        return filtered
    }

    var hasActiveFilters: Bool {
        !selectedTags.isEmpty
            || ageFilter != .all
            || confidenceFilter != .all
            || confirmationFilter != .all
            || !searchText.isEmpty
    }

    private func currentFactFilter() -> FactFilter? {
        let now = Date()
        let cal = Calendar.current
        let weekAgo = cal.date(byAdding: .day, value: -7, to: now)
        let monthAgo = cal.date(byAdding: .day, value: -30, to: now)

        let minConf: Double? = {
            switch confidenceFilter {
            case .all: return nil
            case .highConfidence: return 0.85
            case .mediumConfidence: return 0.5
            case .lowConfidence: return nil   // upper-bounded client-side; see below
            }
        }()

        let createdSince: Date? = {
            switch ageFilter {
            case .lastWeek: return weekAgo
            case .lastMonth: return monthAgo
            default: return nil
            }
        }()

        let createdBefore: Date? = (ageFilter == .older) ? monthAgo : nil

        return FactFilter(
            tags: selectedTags.isEmpty ? nil : Array(selectedTags),
            entities: nil,
            includeExpired: true,           // inspection wants everything
            includeSuperseded: true,
            includePrivate: true,           // togglable client-side via showPrivate
            minConfidence: minConf,
            createdSince: createdSince,
            createdBefore: createdBefore
        )
    }
}
