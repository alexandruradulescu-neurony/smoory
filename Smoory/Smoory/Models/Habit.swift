import Foundation
import SwiftData

@Model
final class Habit {
    var id: UUID = UUID()
    var role: Role?
    var parentGoal: Goal?
    var title: String = ""
    var targetCadence: Cadence = Cadence.daily
    var targetCount: Int = 1
    var lastLoggedAt: Date?
    var currentStreak: Int = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init() {}
}
