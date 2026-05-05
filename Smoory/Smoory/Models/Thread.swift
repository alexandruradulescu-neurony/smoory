import Foundation
import SwiftData

// Note: this entity shadows `Foundation.Thread` within the Smoory module.
// Use `Foundation.Thread` if the system thread type is ever needed.
// See DECISIONS.md decision 8.
@Model
final class Thread {
    var id: UUID = UUID()
    var role: Role?
    var title: String = ""
    var summary: String = ""
    var status: ThreadStatus = ThreadStatus.open
    var inferred: Bool = false
    var inferenceConfidence: Double?
    var relatedProject: Project?
    var emails: [EmailReference] = []
    var events: [ThreadEvent] = []
    var closedAt: Date?
    var closedReason: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(inverse: \UserListItem.parentThread)
    var listItems: [UserListItem] = []

    var people: [Person] = []          // unidirectional — Person does not declare an inverse

    init() {}
}
