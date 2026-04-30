import Foundation
import Observation

@Observable
@MainActor
final class TurnsListViewModel {
    let hema: HemaService

    private(set) var allTurns: [MemoryTurn] = []
    private(set) var isLoading = false
    private(set) var loadError: String?

    var searchText: String = ""
    var dateRangeFilter: DateRangeFilter = .all
    var roleFilter: RoleFilter = .all

    enum DateRangeFilter: Hashable, CaseIterable, Identifiable {
        case all, today, lastWeek, lastMonth, older
        var id: Self { self }
        var title: String {
            switch self {
            case .all: "Any time"
            case .today: "Today"
            case .lastWeek: "Last week"
            case .lastMonth: "Last month"
            case .older: "Older than month"
            }
        }
    }

    enum RoleFilter: Hashable, CaseIterable, Identifiable {
        case all, user, assistant
        var id: Self { self }
        var title: String {
            switch self {
            case .all: "Any role"
            case .user: "User"
            case .assistant: "Smoory"
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
            let now = Date()
            let cal = Calendar.current
            let startOfToday = cal.startOfDay(for: now)
            let weekAgo = cal.date(byAdding: .day, value: -7, to: now)
            let monthAgo = cal.date(byAdding: .day, value: -30, to: now)

            let since: Date? = {
                switch dateRangeFilter {
                case .today: return startOfToday
                case .lastWeek: return weekAgo
                case .lastMonth: return monthAgo
                default: return nil
                }
            }()
            let before: Date? = (dateRangeFilter == .older) ? monthAgo : nil
            let role: MemoryTurn.Role? = {
                switch roleFilter {
                case .user: return .user
                case .assistant: return .assistant
                default: return nil
                }
            }()

            allTurns = try await hema.readAllTurns(
                limit: 500,
                offset: 0,
                since: since,
                before: before,
                role: role
            )
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Search applied client-side over the loaded set.
    var displayedTurns: [MemoryTurn] {
        if searchText.isEmpty { return allTurns }
        let q = searchText.lowercased()
        return allTurns.filter { $0.content.lowercased().contains(q) }
    }

    /// Grouped by chat session, oldest session first within the page; turns within a session
    /// kept in newest-first order (matches the load order from hema).
    var groupedBySession: [(sessionID: UUID, turns: [MemoryTurn])] {
        let grouped = Dictionary(grouping: displayedTurns) { $0.chatSessionID }
        return grouped
            .map { ($0.key, $0.value) }
            .sorted { lhs, rhs in
                let lTop = lhs.1.first?.createdAt ?? .distantPast
                let rTop = rhs.1.first?.createdAt ?? .distantPast
                return lTop > rTop
            }
    }

    var hasActiveFilters: Bool {
        dateRangeFilter != .all || roleFilter != .all || !searchText.isEmpty
    }
}
