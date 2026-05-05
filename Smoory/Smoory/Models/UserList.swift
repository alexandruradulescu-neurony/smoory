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

    // MARK: - Recurrence reset (4.8d)

    /// Auto-reset cadence — clears `isCompleted` on every item in the list at the next
    /// daily/weekly/monthly boundary after `lastResetAt`. 0 = no reset (default).
    /// Reset enforcement runs on app foreground; see `UserList.performResetIfDue`.
    var resetCadenceRaw: Int = 0
    /// Timestamp of the last reset run. nil = never reset; treated as "due" the first
    /// time enforcement runs after `resetCadenceRaw` is set non-zero.
    var lastResetAt: Date?

    /// `EKCalendar.calendarIdentifier` once paired with a Reminders.app list. nil for
    /// notes-kind lists, lists created before Reminders sync was enabled, and lists
    /// created while permission was denied. Set/cleared by `RemindersSyncService` only.
    var eventKitIdentifier: String?

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

    var resetCadence: UserListResetCadence {
        get { UserListResetCadence(rawValue: resetCadenceRaw) ?? .none }
        set { resetCadenceRaw = newValue.rawValue }
    }

    /// Returns true if a reset is due for this list (cadence non-none and `lastResetAt`
    /// older than the cadence's most recent boundary). Pure read — caller drives the
    /// actual reset by calling `performResetIfDue`.
    func isResetDue(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let cadence = resetCadence
        guard cadence != .none, kind == .checklist else { return false }
        guard let boundary = cadence.mostRecentBoundary(now: now, calendar: calendar) else {
            return false
        }
        guard let last = lastResetAt else { return true }
        return last < boundary
    }

    /// Clears `isCompleted` on every checklist item and stamps `lastResetAt = now`.
    /// Caller commits the SwiftData context after.
    func performReset(now: Date = Date()) {
        guard kind == .checklist else { return }
        for item in items where item.isCompleted {
            item.isCompleted = false
            item.completedAt = nil
            item.updatedAt = now
        }
        lastResetAt = now
        updatedAt = now
    }
}

/// Auto-reset cadence for a checklist-kind UserList. .none = no reset (default).
/// 4.8d — picked from the list header detail menu. The "groceries reset weekly"
/// pattern is `weekly` with the user's chosen anchor day.
extension UserList {
    /// Sweeps every non-archived list, running `performReset` on each that's due.
    /// Called from the app's `.task` and `scenePhase → .active` hook so foreground
    /// returns reset the right lists before the user looks at them.
    @MainActor
    static func runResetSweepIfDue(modelContainer: ModelContainer) {
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<UserList>()
        descriptor.fetchLimit = 1000
        guard let lists = try? context.fetch(descriptor) else { return }
        let now = Date()
        var changed = false
        for list in lists where !list.isArchived && list.isResetDue(now: now) {
            list.performReset(now: now)
            changed = true
        }
        if changed {
            try? context.save()
        }
    }
}

enum UserListResetCadence: Int, Codable, Sendable, CaseIterable {
    case none    = 0
    case daily   = 1
    case weekly  = 2
    case monthly = 3

    var displayLabel: String {
        switch self {
        case .none: return "No auto-reset"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }

    /// Most-recent boundary for this cadence. Used by `UserList.isResetDue` to detect
    /// when `lastResetAt` is on the wrong side of the most recent reset window.
    func mostRecentBoundary(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .none: return nil
        case .daily:
            return calendar.startOfDay(for: now)
        case .weekly:
            // Week starts on the calendar's first weekday (locale-dependent — Mon in
            // ISO locales, Sun in US). Honors the user's system setting.
            let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            return calendar.date(from: comps)
        case .monthly:
            let comps = calendar.dateComponents([.year, .month], from: now)
            return calendar.date(from: comps)
        }
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
