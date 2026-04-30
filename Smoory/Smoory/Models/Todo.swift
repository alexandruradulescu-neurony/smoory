import Foundation
import SwiftData

@Model
final class Todo {
    var id: UUID = UUID()
    var role: Role?
    var parentProject: Project?
    var parentThread: Thread?
    var title: String = ""
    var notes: String = ""
    var dueDate: Date?
    var priority: TodoPriority = TodoPriority.normal
    var isCompleted: Bool = false
    var completedAt: Date?
    var deferredFrom: Date?
    var deferralCount: Int = 0
    var source: TodoSource = TodoSource.manual
    var relatedPeople: [Person] = []
    var parentTodo: Todo?
    @Relationship(deleteRule: .cascade, inverse: \Todo.parentTodo)
    var subtasks: [Todo] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init() {}
}

extension Todo {
    /// (completed, total) — empty parent returns (0, 0).
    var subtaskProgress: (completed: Int, total: Int) {
        let total = subtasks.count
        let completed = subtasks.filter(\.isCompleted).count
        return (completed, total)
    }

    var isTopLevel: Bool { parentTodo == nil }
}
