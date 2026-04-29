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
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init() {}
}
