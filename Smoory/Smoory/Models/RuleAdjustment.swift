import Foundation
import SwiftData

@Model
final class RuleAdjustment {
    var id: UUID = UUID()
    var kind: RuleKind = RuleKind.autoArchiveSender
    var details: String = ""           // spec field: description (renamed — see DECISIONS.md decision 9)
    var pattern: String = ""
    var weight: Double = 0.0
    var confirmed: Bool = false
    var proposedAt: Date = Date()
    var confirmedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init() {}
}
