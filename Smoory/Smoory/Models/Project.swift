import Foundation
import SwiftData

@Model
final class Project {
    var id: UUID = UUID()
    var role: Role?
    var parentGoal: Goal?
    var title: String = ""
    var details: String = ""           // spec field: description (renamed — see DECISIONS.md decision 9)
    var status: ProjectStatus = ProjectStatus.planning
    var targetDate: Date?
    var completedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(inverse: \UserListItem.parentProject)
    var listItems: [UserListItem] = []

    @Relationship(inverse: \Thread.relatedProject)
    var threads: [Thread] = []

    @Relationship(inverse: \CaptureItem.pinnedToProject)
    var notes: [CaptureItem] = []

    init() {}
}
