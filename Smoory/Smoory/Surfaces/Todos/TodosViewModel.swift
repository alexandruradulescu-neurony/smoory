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

    /// Top-level todos for the active status filter, search-filtered, grouped by DueDateGroup.
    /// Subtasks are NOT included in the flat list — they appear under their parent on expansion.
    func groupedTodos(from allTodos: [Todo]) -> [(DueDateGroup, [Todo])] {
        let topLevel = allTodos.filter { $0.parentTodo == nil && matchesFilter($0) }

        let filtered: [Todo]
        if searchText.isEmpty {
            filtered = topLevel
        } else {
            let query = searchText.lowercased()
            filtered = topLevel.filter { $0.title.lowercased().contains(query) }
        }

        let grouped = Dictionary(grouping: filtered) { DueDateGroup.group(for: $0) }

        return DueDateGroup.allCases.compactMap { groupKey in
            guard let todos = grouped[groupKey], !todos.isEmpty else { return nil }
            let sorted = todos.sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority.rawValue > rhs.priority.rawValue
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

    private func matchesFilter(_ todo: Todo) -> Bool {
        switch statusFilter {
        case .open: return !todo.isCompleted && !todo.isArchived
        case .completed: return todo.isCompleted && !todo.isArchived
        case .archived: return todo.isArchived
        }
    }
}
