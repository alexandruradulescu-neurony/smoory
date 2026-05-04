import Foundation

/// Live calendar snapshot written into the App Group container so the desktop
/// widget renders today's actual events without re-reading EventKit. Updated
/// at app launch and on the 5-minute polling tick. The widget computes
/// per-event status (completed / happening / upcoming) at render time using
/// `entry.date`, so this snapshot's `updatedAt` does not need to be fresh —
/// only the event list does.
struct CalendarSnapshot: Codable, Sendable {
    let updatedAt: Date
    let forDate: Date              // start of today, local timezone
    let events: [CalendarEventEntry]

    struct CalendarEventEntry: Codable, Sendable {
        let title: String
        let startTime: Date
        let endTime: Date
        let isAllDay: Bool
        let location: String?
    }
}

/// Live todos snapshot written into the App Group container after every todo
/// mutation. `openCount` is the count of currently-open top-level todos;
/// `totalCount` is `openCount + completed-since-midnight`. Used by the widget
/// to render the "X of Y done" progress header.
struct TodosSnapshot: Codable, Sendable {
    let updatedAt: Date
    let openCount: Int
    let totalCount: Int
    let openTodos: [TodoSnapshotEntry]

    struct TodoSnapshotEntry: Codable, Sendable {
        let id: String             // Todo.id.uuidString
        let title: String
        let priority: String?      // "low" | "normal" | "high" | "urgent" or nil
        let dueDate: Date?
        let hasSubtasks: Bool
    }
}
