import Foundation
import SwiftData

/// One row inside a `UserList`. `isCompleted` is meaningful only for `.checklist` kind;
/// the field is preserved on `.notes` kind so a list can be re-typed without data loss.
/// See DECISIONS.md §4.6 and §4.8a.
@Model
final class UserListItem {
    var id: UUID = UUID()
    var text: String = ""
    var isCompleted: Bool = false
    var completedAt: Date?
    var order: Int = 0          // stable display order; new items appended via UserList.nextItemOrder
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// `EKReminder.calendarItemIdentifier` once paired with a Reminders.app reminder.
    /// nil for items in notes-kind lists, items created pre-permission, or items not
    /// yet synced. Set/cleared by `RemindersSyncService` only.
    var eventKitIdentifier: String?

    // MARK: - Reminders-parity fields (4.8a)

    /// Long-form note attached to the item. Round-trips with `EKReminder.notes`.
    var notes: String?
    /// EKReminder.priority semantics: 0 = none, 1–4 = low, 5 = medium, 6–9 = high.
    /// We store the raw integer rather than a Smoory enum so the round-trip with EK
    /// is a no-op cast.
    var priority: Int = 0
    /// When the item is due. nil = no due date. Combined with `hasTime` to round-trip
    /// with `EKReminder.dueDateComponents` — date-only on the EK side has no hour/minute,
    /// date+time has all components.
    var dueDate: Date?
    /// True when `dueDate` carries a meaningful hour+minute. False = the user said
    /// "due Friday" (date only); EK side serializes as DateComponents without hour.
    var hasTime: Bool = false
    /// Optional URL the user attached to the item. Round-trips with `EKReminder.url`.
    var urlString: String?

    // MARK: - Todo-absorption fields (4.8b)

    /// Self-referential parent for hierarchy. Mirrors the Todo→Todo subtask relationship
    /// so a UserListItem can represent a parent task with checkable subtasks beneath it.
    var parentItem: UserListItem?
    /// Subtasks — cascade-deleted with the parent. Inverse of `parentItem`.
    @Relationship(deleteRule: .cascade, inverse: \UserListItem.parentItem)
    var subtasks: [UserListItem] = []

    /// Optional role this item belongs to (work / personal / freelance). Lets a list item
    /// participate in the same review-loop semantics that day/week reviews apply to Todos.
    var role: Role?
    /// Optional project association. Inverse not declared on `Project` to keep that side
    /// stable — Project.parentTodo doesn't need to flip into a heterogeneous list.
    var parentProject: Project?
    /// Optional thread association — same reasoning as project.
    var parentThread: Thread?
    /// People referenced by the item. Phase 1 type; same-shape as Todo.relatedPeople.
    var relatedPeople: [Person] = []

    /// Source provenance. Stored as Int raw with the same case set as `TodoSource` so
    /// the day-end batched extractor can group by source identically across both kinds.
    /// 0 = userChat, 1 = userQuickadd, 2 = aiProposal, 3 = emailExtraction,
    /// 4 = calendarExtraction, 5 = manual.
    var sourceRaw: Int = 0
    /// Number of times this item has been deferred (pushed to a later date). Phase 3
    /// pattern analysis uses the count to surface "you've moved this 3 times" signals.
    var deferralCount: Int = 0
    /// Last-known due date before the most recent deferral — kept so pattern analysis
    /// can surface "originally due X, now due Y".
    var deferredFrom: Date?

    /// Soft-delete flag at the item level (distinct from `UserList.isArchived`, which
    /// hides the entire list). Lets a single item be archived without removing it from
    /// the list — useful when a user changes their mind.
    var isArchived: Bool = false
    var archivedAt: Date?

    var list: UserList?         // inverse — set by SwiftData via UserList.items

    init() {}
}

extension UserListItem {
    /// Convenience: a normalized priority bucket for UI sort + display. Maps the EK
    /// 0–9 scale to {none, low, medium, high} so rows can render a consistent badge.
    enum PriorityBucket: Int, Sendable {
        case none, low, medium, high

        var displayLabel: String {
            switch self {
            case .none: return ""
            case .low: return "Low"
            case .medium: return "Medium"
            case .high: return "High"
            }
        }

        var symbolName: String? {
            switch self {
            case .none: return nil
            case .low: return "exclamationmark"
            case .medium: return "exclamationmark.2"
            case .high: return "exclamationmark.3"
            }
        }
    }

    var priorityBucket: PriorityBucket {
        switch priority {
        case 0: return .none
        case 1...4: return .low
        case 5: return .medium
        case 6...9: return .high
        default: return .none
        }
    }

    /// Resolved `URL?` from `urlString`. Nil for empty / malformed strings.
    var url: URL? {
        guard let raw = urlString, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// Source provenance (4.8b). Mirrors `TodoSource` so day-end extraction can group
    /// list items by source identically to how it grouped Todos.
    var source: UserListItemSource {
        get { UserListItemSource(rawValue: sourceRaw) ?? .userChat }
        set { sourceRaw = newValue.rawValue }
    }

    /// (completed, total) over direct subtasks. Mirror of `Todo.subtaskProgress`.
    var subtaskProgress: (completed: Int, total: Int) {
        let total = subtasks.count
        let completed = subtasks.filter(\.isCompleted).count
        return (completed, total)
    }

    /// Convenience: this item is at the top of the hierarchy (no parent item).
    var isTopLevel: Bool { parentItem == nil }
}

/// Source provenance for a `UserListItem`. Same case set as `TodoSource` (4.8b
/// migration parity) so any code that grouped Todos by source can read the new
/// field with no semantic shift.
enum UserListItemSource: Int, Codable, Sendable {
    case userChat = 0
    case userQuickadd = 1
    case aiProposal = 2
    case emailExtraction = 3
    case calendarExtraction = 4
    case manual = 5
}
