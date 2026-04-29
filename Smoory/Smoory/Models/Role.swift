import Foundation
import SwiftData

@Model
final class Role {
    var id: UUID = UUID()
    var name: String = ""
    var slug: String = ""
    var details: String = ""           // spec field: description (renamed — see DECISIONS.md decision 9)
    var colorHex: String = "#888888"
    var workingHours: WorkingHours?
    var priorityWeight: Double = 1.0
    var isActive: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(inverse: \Goal.role)
    var goals: [Goal] = []

    @Relationship(inverse: \Project.role)
    var projects: [Project] = []

    @Relationship(inverse: \Thread.role)
    var threads: [Thread] = []

    @Relationship(inverse: \Todo.role)
    var todos: [Todo] = []

    init() {}
}
