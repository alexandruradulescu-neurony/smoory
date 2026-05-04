import Foundation
import SwiftData
import WidgetKit

/// Builds the live todos snapshot the desktop widget reads. Called from every
/// todo mutation site (8 tools + app launch) after `context.save()` lands. Uses
/// the same priority/dueDate/createdAt sort order as `TodosViewModel` so the
/// widget list matches what the user sees in the app's Todos surface.
///
/// Pragmatic alternative to a full `TodosService` refactor — see
/// `docs/smoory-spec/PHASE_4_NOTES.md` for the deferred-service note.
@MainActor
enum TodosSnapshotWriter {
    static func writeFromStore(_ modelContainer: ModelContainer) {
        let context = ModelContext(modelContainer)

        // Open top-level todos: not completed, not archived, no parent.
        let openDescriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> {
                $0.isCompleted == false && $0.isArchived == false && $0.parentTodo == nil
            }
        )
        let openTodos = (try? context.fetch(openDescriptor)) ?? []

        // Completed-today count (top-level only, not archived) — drives the
        // "X of Y done" header. SwiftData #Predicate's nullable Date comparisons
        // are quirky, so fetch all completed top-level rows and filter in Swift.
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let completedDescriptor = FetchDescriptor<Todo>(
            predicate: #Predicate<Todo> {
                $0.isCompleted == true && $0.isArchived == false && $0.parentTodo == nil
            }
        )
        let allCompleted = (try? context.fetch(completedDescriptor)) ?? []
        let completedTodayCount = allCompleted.filter {
            ($0.completedAt ?? .distantPast) >= startOfToday
        }.count

        // Match TodosViewModel's sort order: priority DESC, dueDate ASC nulls-last,
        // createdAt ASC.
        let sorted = openTodos.sorted { a, b in
            if a.priority.rawValue != b.priority.rawValue {
                return a.priority.rawValue > b.priority.rawValue
            }
            switch (a.dueDate, b.dueDate) {
            case let (l?, r?):
                if l != r { return l < r }
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            default:
                break
            }
            return a.createdAt < b.createdAt
        }

        let entries = sorted.map { todo -> TodosSnapshot.TodoSnapshotEntry in
            TodosSnapshot.TodoSnapshotEntry(
                id: todo.id.uuidString,
                title: todo.title,
                priority: priorityString(todo.priority),
                dueDate: todo.dueDate,
                hasSubtasks: !todo.subtasks.isEmpty
            )
        }

        let snapshot = TodosSnapshot(
            updatedAt: Date(),
            openCount: openTodos.count,
            totalCount: openTodos.count + completedTodayCount,
            openTodos: entries
        )

        AppGroupContainerWriter()?.writeTodosSnapshot(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func priorityString(_ p: TodoPriority) -> String? {
        switch p {
        case .low: "low"
        case .normal: "normal"
        case .high: "high"
        case .urgent: "urgent"
        }
    }
}
