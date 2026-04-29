import Foundation
import SwiftData

@Model
final class Infrastructure {
    var id: UUID = UUID()
    var name: String = ""
    var category: InfraCategory = InfraCategory.other
    var role: Role?
    var provider: String?
    var notes: String = ""
    var senderHints: [String] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init() {}
}
