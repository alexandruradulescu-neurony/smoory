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
