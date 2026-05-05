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

        // Open top-level "todo-shaped" UserListItems (4.8c). The "todo" filter mirrors
        // GetOpenTodosTool: any open top-level item with a due date, priority, or
        // role/project/thread anchor. Plain shopping/reading list rows without those
        // signals don't appear in the widget.
        let openDescriptor = FetchDescriptor<UserListItem>(
            predicate: #Predicate<UserListItem> {
                $0.isCompleted == false && $0.isArchived == false && $0.parentItem == nil
            }
        )
        let openItems = (try? context.fetch(openDescriptor)) ?? []
        let openTodos = openItems.filter { item in
            item.dueDate != nil
                || item.priority > 0
                || item.role != nil
                || item.parentProject != nil
                || item.parentThread != nil
        }

        // Completed-today count — same filter, completed branch.
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let completedDescriptor = FetchDescriptor<UserListItem>(
            predicate: #Predicate<UserListItem> {
                $0.isCompleted == true && $0.isArchived == false && $0.parentItem == nil
            }
        )
        let allCompleted = (try? context.fetch(completedDescriptor)) ?? []
        let completedTodayCount = allCompleted.filter { item in
            guard (item.completedAt ?? .distantPast) >= startOfToday else { return false }
            return item.dueDate != nil
                || item.priority > 0
                || item.role != nil
                || item.parentProject != nil
                || item.parentThread != nil
        }.count

        // Match TodosViewModel's sort order: priority DESC, dueDate ASC nulls-last,
        // createdAt ASC.
        let sorted = openTodos.sorted { a, b in
            if a.priority != b.priority {
                return a.priority > b.priority
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

        let entries = sorted.map { item -> TodosSnapshot.TodoSnapshotEntry in
            TodosSnapshot.TodoSnapshotEntry(
                id: item.id.uuidString,
                title: item.text,
                priority: priorityString(item.priority),
                dueDate: item.dueDate,
                hasSubtasks: !item.subtasks.isEmpty
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

    /// Maps the EK 0–9 priority scale onto the snapshot's 4-bucket strings the widget
    /// already expects. Mirrors `UserListItem.PriorityBucket`.
    private static func priorityString(_ p: Int) -> String? {
        switch p {
        case 0: return nil
        case 1...4: return "low"
        case 5: return "normal"
        case 6...8: return "high"
        case 9: return "urgent"
        default: return nil
        }
    }

}
