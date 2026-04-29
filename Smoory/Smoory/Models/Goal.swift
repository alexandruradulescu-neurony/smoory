import Foundation
import SwiftData

@Model
final class Goal {
    var id: UUID = UUID()
    var role: Role?
    var title: String = ""
    var details: String = ""           // spec field: description (renamed — see DECISIONS.md decision 9)
    var goalType: GoalType = GoalType.reflective
    var trackedSignal: TrackedSignal?
    var reflectiveCadence: ReflectiveCadence?
    var status: GoalStatus = GoalStatus.active
    var targetDate: Date?
    var lastCheckInAt: Date?
    var lastNudgedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(inverse: \Project.parentGoal)
    var projects: [Project] = []

    @Relationship(inverse: \Habit.parentGoal)
    var habits: [Habit] = []

    init() {}
}
