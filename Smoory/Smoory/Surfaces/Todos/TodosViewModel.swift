import Foundation
import Observation

enum TodoStatusFilter: Hashable, CaseIterable, Identifiable {
    case open, completed, archived
    var id: Self { self }
    var title: String {
        switch self {
        case .open: "Open"
        case .completed: "Completed"
        case .archived: "Archived"
        }
    }
}

@Observable
@MainActor
final class TodosViewModel {
    var searchText: String = ""
    var statusFilter: TodoStatusFilter = .open

    /// Top-level UserListItems for the active status filter, search-filtered, grouped
    /// by DueDateGroup. Subtasks are NOT included in the flat list — they appear under
    /// their parent on expansion. 4.8c — backing entity is `UserListItem` with the
    /// "todo-shaped" filter (any item with a due date, priority, role, project, or
    /// thread anchor) so plain shopping/reading list rows don't pollute the Todos view.
    func groupedTodos(from allItems: [UserListItem]) -> [(DueDateGroup, [UserListItem])] {
        let topLevel = allItems.filter { item in
            guard item.parentItem == nil, matchesFilter(item) else { return false }
            return item.dueDate != nil
                || item.priority > 0
                || item.role != nil
                || item.parentProject != nil
                || item.parentThread != nil
        }

        let filtered: [UserListItem]
        if searchText.isEmpty {
            filtered = topLevel
        } else {
            let query = searchText.lowercased()
            filtered = topLevel.filter { $0.text.lowercased().contains(query) }
        }

        let grouped = Dictionary(grouping: filtered) { DueDateGroup.group(for: $0) }

        return DueDateGroup.allCases.compactMap { groupKey in
            guard let items = grouped[groupKey], !items.isEmpty else { return nil }
            let sorted = items.sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority > rhs.priority
                }
                switch (lhs.dueDate, rhs.dueDate) {
                case let (l?, r?):
                    return l < r
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return lhs.createdAt < rhs.createdAt
                }
            }
            return (groupKey, sorted)
        }
    }

    private func matchesFilter(_ item: UserListItem) -> Bool {
        switch statusFilter {
        case .open: return !item.isCompleted && !item.isArchived
        case .completed: return item.isCompleted && !item.isArchived
        case .archived: return item.isArchived
        }
    }
}
