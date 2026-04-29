import Foundation
import SwiftData

@Model
final class Person {
    var id: UUID = UUID()
    var appleContactId: String?
    var displayName: String = ""
    var aliases: [String] = []
    var primaryEmail: String?
    var emails: [String] = []
    var company: String?
    var jobTitle: String?              // spec field: title (renamed for clarity vs. Goal/Project/Todo titles)
    var roles: [Role] = []             // many-to-many; Role does not declare an inverse
    var relationship: String = ""
    var howWeMet: String?
    var notes: String = ""
    var tags: [String] = []
    var tone: ToneProfile?
    var tonePolicyOverride: ToneOverride?
    var lastInteractionAt: Date?
    var interactionCount: Int = 0
    var isTracked: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init() {}
}
