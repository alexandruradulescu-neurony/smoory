import Foundation
import SwiftData

/// One row inside a `UserList`. `isCompleted` is meaningful only for `.checklist` kind;
/// the field is preserved on `.notes` kind so a list can be re-typed without data loss.
/// See DECISIONS.md §4.6.
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
    var list: UserList?         // inverse — set by SwiftData via UserList.items

    init() {}
}
