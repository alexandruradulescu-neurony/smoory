import Foundation
import SwiftData

/// A user-stated stretch of unavailability — vacation, sick day, holiday, personal time.
/// Replaces the Phase 3 stopgap (availability candidates persisted as semantic facts);
/// see DECISIONS.md §4.9. The proactive proposal generator surfaces todo / calendar
/// conflicts as feed cards when an `OffPeriod` is created.
@Model
final class OffPeriod {
    var id: UUID = UUID()
    /// First day of the off-period (inclusive). Date-only at creation; the proactive
    /// generator treats it as `startOfDay` to find conflicts.
    var startDate: Date = Date()
    /// Last day of the off-period (inclusive). The generator queries up to `endOfDay`.
    var endDate: Date = Date()
    /// `OffPeriodKind` raw value. Default `.personal`.
    var kindRaw: Int = OffPeriodKind.personal.rawValue
    /// Free-form annotation ("dentist", "wedding", "trip to Lisbon"). Defaults blank.
    var notes: String = ""
    /// Role this off-period applies to. nil = applies across all roles. Lets a user
    /// be "off from work but available for personal" in the data model even if v1
    /// doesn't surface the distinction yet.
    var role: Role?
    /// Audit link to the structuring `CandidateWrite` that produced this row, when
    /// applicable. nil for OffPeriods created directly (none in 4.9, reserved for
    /// future tool-side creation).
    var sourceCandidateID: UUID?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init() {}
}

extension OffPeriod {
    var kind: OffPeriodKind {
        get { OffPeriodKind(rawValue: kindRaw) ?? .personal }
        set { kindRaw = newValue.rawValue }
    }

    /// True when `now` is within `[startDate, endDate]` (inclusive of the entire end day).
    func isActive(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) ?? endDate
        return now >= start && now < end
    }

    /// True when the period entirely precedes `now` (whole end day already passed).
    func isPast(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let endOfEndDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) ?? endDate
        return endOfEndDay <= now
    }

    /// True when the period hasn't started yet.
    var isUpcoming: Bool {
        let cal = Calendar.current
        let start = cal.startOfDay(for: startDate)
        return start > Date()
    }

    /// Inclusive day count. A single-day off-period returns 1.
    var dayCount: Int {
        let cal = Calendar.current
        let start = cal.startOfDay(for: startDate)
        let end = cal.startOfDay(for: endDate)
        let comps = cal.dateComponents([.day], from: start, to: end)
        return max(1, (comps.day ?? 0) + 1)
    }

    /// Compact label used in Settings rows + feed cards. Examples:
    ///   "May 4 – May 6 · Vacation"
    ///   "May 4 · Sick"
    ///   "May 4 – May 6 · Vacation (Lisbon)"
    var displayLabel: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale.current

        let cal = Calendar.current
        let isSingleDay = cal.isDate(startDate, inSameDayAs: endDate)
        let dateText = isSingleDay
            ? formatter.string(from: startDate)
            : "\(formatter.string(from: startDate)) – \(formatter.string(from: endDate))"

        var label = "\(dateText) · \(kind.displayLabel)"
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            label += " (\(trimmedNotes))"
        }
        return label
    }
}
