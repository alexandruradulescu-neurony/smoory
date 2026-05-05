import Foundation
import SwiftData

/// User-curated collection (reading list, packing list, groceries, gift ideas, etc.).
/// Distinct from `Todo`: a Todo is a tactical commitment with priority/deadline; a list
/// item is a curated entry in a collection. See DECISIONS.md §4.6.
@Model
final class UserList {
    var id: UUID = UUID()
    var title: String = ""
    var kindRaw: Int = UserListKind.checklist.rawValue
    var isArchived: Bool = false
    var archivedAt: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(deleteRule: .cascade, inverse: \UserListItem.list)
    var items: [UserListItem] = []

    init() {}
}

extension UserList {
    var kind: UserListKind {
        get { UserListKind(rawValue: kindRaw) ?? .checklist }
        set { kindRaw = newValue.rawValue }
    }

    var itemCount: Int { items.count }

    /// Number of completed items. Always 0 for `.notes` kind (the field exists on items
    /// for type-flip safety but is ignored in that kind's UI).
    var completedCount: Int { items.filter(\.isCompleted).count }

    /// Order to assign to a freshly-appended item: max existing order + 1, or 0 if empty.
    var nextItemOrder: Int {
        (items.map(\.order).max() ?? -1) + 1
    }
}

enum UserListKind: Int, Codable, CaseIterable, Sendable {
    case checklist = 0   // items have isCompleted; UI shows checkbox
    case notes = 1       // items are plain bullets; isCompleted hidden in UI

    /// String form used over the chat tool boundary. Stable — schema migrations should
    /// preserve these spellings.
    var wireValue: String {
        switch self {
        case .checklist: "checklist"
        case .notes: "notes"
        }
    }

    init?(wireValue: String) {
        switch wireValue.lowercased() {
        case "checklist": self = .checklist
        case "notes": self = .notes
        default: return nil
        }
    }
}
