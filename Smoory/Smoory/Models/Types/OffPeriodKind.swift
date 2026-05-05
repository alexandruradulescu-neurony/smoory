import Foundation

/// Reason for a stretch of unavailability. Stored as Int raw on `OffPeriod.kindRaw`
/// per CLAUDE.md SwiftData rules. The enum is intentionally coarse — finer-grained
/// reasons (e.g., "doctor's appointment", "school pickup") belong on the OffPeriod's
/// `notes` field rather than as enum cases.
enum OffPeriodKind: Int, Codable, Sendable, CaseIterable {
    case vacation = 0
    case sick     = 1
    case holiday  = 2
    case personal = 3
    case other    = 4

    var displayLabel: String {
        switch self {
        case .vacation: return "Vacation"
        case .sick: return "Sick"
        case .holiday: return "Holiday"
        case .personal: return "Personal"
        case .other: return "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .vacation: return "sun.max"
        case .sick: return "thermometer"
        case .holiday: return "gift"
        case .personal: return "person.crop.circle"
        case .other: return "calendar.badge.clock"
        }
    }
}
