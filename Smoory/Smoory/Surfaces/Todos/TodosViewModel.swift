import Foundation
import Observation

@Observable
@MainActor
final class TodosViewModel {
    var searchText: String = ""

    /// Top-level open todos, filtered by searchText, grouped by DueDateGroup.
    /// Subtasks are NOT included in the flat list — they appear under their
    /// parent on expansion.
    func groupedTodos(from allTodos: [Todo]) -> [(DueDateGroup, [Todo])] {
        let topLevel = allTodos.filter { $0.parentTodo == nil && !$0.isCompleted }

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
}
