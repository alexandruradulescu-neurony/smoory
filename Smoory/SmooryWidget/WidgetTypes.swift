import Foundation

// MARK: - Morning brief mirrors
//
// These types must match the JSON shapes written by the main app's
// MorningBrief.swift and AppGroupContainerWriter.swift exactly. Field renames
// in the main app are breaking changes for the widget — synchronize the two
// when changing the schema.

struct WidgetMorningBrief: Codable {
    let id: UUID
    let generatedAt: Date
    let forDate: Date
    let headline: String
    let secondaryItems: [WidgetSecondaryItem]
    let calendar: [WidgetCalendarItem]
    let reflectiveNote: String?
    let goalNudge: WidgetGoalNudge?

    static let preview = WidgetMorningBrief(
        id: UUID(),
        generatedAt: Date(),
        forDate: Date(),
        headline: "Apollo migration ships at 2pm — morning is yours for deep work.",
        secondaryItems: [
            WidgetSecondaryItem(icon: "checkmark.circle", text: "Review the migration runbook", kind: "todo"),
            WidgetSecondaryItem(icon: "calendar", text: "Standup at 10:00", kind: "calendar")
        ],
        calendar: [
            WidgetCalendarItem(
                title: "Standup",
                startTime: Date(),
                endTime: Date().addingTimeInterval(1800),
                isAllDay: false,
                location: nil
            )
        ],
        reflectiveNote: "Yesterday's review noted you wanted to call your mother — evening looks free.",
        goalNudge: nil
    )
}

struct WidgetSecondaryItem: Codable, Hashable {
    let icon: String
    let text: String
    let kind: String
}

struct WidgetCalendarItem: Codable, Hashable {
    let title: String
    let startTime: Date
    let endTime: Date
    let isAllDay: Bool
    let location: String?
}

struct WidgetGoalNudge: Codable, Hashable {
    let goalTitle: String
    let nudgeText: String
}

// MARK: - Scheduled actions mirrors

struct WidgetScheduledAction: Codable, Identifiable, Hashable {
    let id: String
    let kind: String
    let scheduledFor: Date
    let content: String
}

/// Top-level shape of scheduled-actions.json: {"updatedAt": ISO, "entries": [...]}.
/// Matches AppGroupContainerWriter.ScheduledActionsSnapshot.
struct WidgetScheduledActionsSnapshot: Codable {
    let updatedAt: Date
    let entries: [WidgetScheduledAction]
}

// MARK: - Live calendar snapshot mirrors (4.1)
//
// Mirror of CalendarSnapshot in the main app. Distinct from WidgetCalendarItem
// (which is the morning brief's static calendar payload) — this one reflects
// today's actual events updated on the 5-min polling tick + at app launch.

struct WidgetCalendarSnapshot: Codable {
    let updatedAt: Date
    let forDate: Date
    let events: [WidgetCalendarEvent]
}

struct WidgetCalendarEvent: Codable, Hashable, Identifiable {
    var id: String { "\(title)-\(startTime.timeIntervalSince1970)" }
    let title: String
    let startTime: Date
    let endTime: Date
    let isAllDay: Bool
    let location: String?
}

// MARK: - Live todos snapshot mirrors (4.1)
//
// Mirror of TodosSnapshot in the main app. Updated after every todo mutation
// (8 instrumented call sites) so the widget shows current open-todo state and
// the "X of Y done" progress header.

struct WidgetTodosSnapshot: Codable {
    let updatedAt: Date
    let openCount: Int
    let totalCount: Int
    let openTodos: [WidgetTodoEntry]
}

struct WidgetTodoEntry: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let priority: String?    // "low" | "normal" | "high" | "urgent" or nil
    let dueDate: Date?
    let hasSubtasks: Bool
}
