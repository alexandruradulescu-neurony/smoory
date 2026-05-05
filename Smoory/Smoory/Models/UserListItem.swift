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
}
