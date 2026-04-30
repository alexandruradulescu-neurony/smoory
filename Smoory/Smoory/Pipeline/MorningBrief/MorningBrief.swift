import Foundation

/// Persisted shape — id/generatedAt/forDate are added at parse time.
struct MorningBrief: Codable, Sendable, Hashable {
    let id: UUID
    let generatedAt: Date
    let forDate: Date

    let headline: String
    let secondaryItems: [SecondaryItem]
    let calendar: [CalendarItem]
    let reflectiveNote: String?
    let goalNudge: GoalNudge?

    struct SecondaryItem: Codable, Sendable, Hashable {
        let icon: String
        let text: String
        let kind: ItemKind

        enum ItemKind: String, Codable, Sendable, Hashable {
            case todo, calendar, goal, observation
        }
    }

    struct CalendarItem: Codable, Sendable, Hashable {
        let title: String
        let startTime: Date
        let endTime: Date
        let isAllDay: Bool
        let location: String?
    }

    struct GoalNudge: Codable, Sendable, Hashable {
        let goalTitle: String
        let nudgeText: String
    }
}

/// Wire-format struct that maps directly to the LLM's JSON output. Decoded first,
/// then mapped to MorningBrief with id/generatedAt/forDate added.
struct MorningBriefPayload: Codable {
    let headline: String
    let secondaryItems: [MorningBrief.SecondaryItem]
    let calendar: [MorningBrief.CalendarItem]
    let reflectiveNote: String?
    let goalNudge: MorningBrief.GoalNudge?
}
