import Foundation
import SwiftData

@Model
final class Profile {
    var id: UUID = UUID()
    var body: String = ""
    var quickFacts: [String] = []
    var lastEditedAt: Date = Date()
    var editedBy: ProfileEditedBy = ProfileEditedBy.user
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init() {}

    /// Singleton accessor — see DECISIONS.md decision 7.
    /// Always go through this rather than instantiating Profile() directly.
    static func fetchOrCreate(in context: ModelContext) -> Profile {
        let descriptor = FetchDescriptor<Profile>()
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let new = Profile()
        context.insert(new)
        return new
    }
}
