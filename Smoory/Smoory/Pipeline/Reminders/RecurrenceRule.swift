import EventKit
import Foundation

/// In-process representation of an RFC 5545 RRULE — a tiny subset matching what
/// Smoory exposes through the UI (frequency, interval, weekday selection, end via
/// COUNT or UNTIL). Used for round-tripping `UserListItem.recurrenceRule`
/// (canonical string on disk) and `EKReminder.recurrenceRules` (Apple struct).
///
/// Out of scope for 4.8d:
///   - BYMONTHDAY / BYMONTH / BYSETPOS / BYYEARDAY (typed monthly/yearly nuance)
///   - SECONDLY / MINUTELY / HOURLY frequencies
///   - Multiple recurrence rules per reminder
///   - Recurrence end dates with explicit timezone offsets — we store as UTC
struct RecurrenceRule: Equatable, Hashable, Sendable {
    enum Frequency: String, Codable, Sendable {
        case daily   = "DAILY"
        case weekly  = "WEEKLY"
        case monthly = "MONTHLY"
        case yearly  = "YEARLY"

        var ekFrequency: EKRecurrenceFrequency {
            switch self {
            case .daily: return .daily
            case .weekly: return .weekly
            case .monthly: return .monthly
            case .yearly: return .yearly
            }
        }

        init?(ek: EKRecurrenceFrequency) {
            switch ek {
            case .daily: self = .daily
            case .weekly: self = .weekly
            case .monthly: self = .monthly
            case .yearly: self = .yearly
            @unknown default: return nil
            }
        }
    }

    enum Weekday: String, Codable, Sendable, CaseIterable {
        case monday    = "MO"
        case tuesday   = "TU"
        case wednesday = "WE"
        case thursday  = "TH"
        case friday    = "FR"
        case saturday  = "SA"
        case sunday    = "SU"

        var ekWeekday: EKWeekday {
            switch self {
            case .monday: return .monday
            case .tuesday: return .tuesday
            case .wednesday: return .wednesday
            case .thursday: return .thursday
            case .friday: return .friday
            case .saturday: return .saturday
            case .sunday: return .sunday
            }
        }

        init?(ek: EKWeekday) {
            switch ek {
            case .monday: self = .monday
            case .tuesday: self = .tuesday
            case .wednesday: self = .wednesday
            case .thursday: self = .thursday
            case .friday: self = .friday
            case .saturday: self = .saturday
            case .sunday: self = .sunday
            @unknown default: return nil
            }
        }
    }

    enum End: Equatable, Hashable, Sendable {
        case never
        case count(Int)
        case until(Date)
    }

    var frequency: Frequency
    var interval: Int = 1
    /// Only meaningful when `frequency == .weekly`. Empty array on other frequencies.
    var daysOfWeek: [Weekday] = []
    var end: End = .never

    // MARK: - String round-trip

    /// Canonical RFC 5545 form. Field order: FREQ, INTERVAL (omitted when 1), BYDAY,
    /// COUNT or UNTIL. Stable enough that `parse(serialize(x)) == x`.
    func serialize() -> String {
        var parts: [String] = ["FREQ=\(frequency.rawValue)"]
        if interval > 1 {
            parts.append("INTERVAL=\(interval)")
        }
        if frequency == .weekly, !daysOfWeek.isEmpty {
            // Sort to preserve canonical order (Mon..Sun) regardless of input order.
            let order: [Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
            let canonical = order.filter { daysOfWeek.contains($0) }
            parts.append("BYDAY=\(canonical.map(\.rawValue).joined(separator: ","))")
        }
        switch end {
        case .never: break
        case .count(let n) where n > 0:
            parts.append("COUNT=\(n)")
        case .until(let date):
            // RFC 5545 UNTIL is in UTC, formatted as YYYYMMDDTHHMMSSZ.
            parts.append("UNTIL=\(Self.formatUntil(date))")
        case .count:
            break  // ignore non-positive count
        }
        return parts.joined(separator: ";")
    }

    /// Best-effort parse. Returns nil on empty input or unparseable FREQ.
    static func parse(_ raw: String) -> RecurrenceRule? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var freq: Frequency?
        var interval: Int = 1
        var days: [Weekday] = []
        var end: End = .never

        let pairs = trimmed.split(separator: ";")
        for pair in pairs {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            let key = kv[0].uppercased()
            let value = String(kv[1])
            switch key {
            case "FREQ":
                freq = Frequency(rawValue: value.uppercased())
            case "INTERVAL":
                if let n = Int(value), n > 0 { interval = n }
            case "BYDAY":
                days = value
                    .split(separator: ",")
                    .compactMap { Weekday(rawValue: $0.trimmingCharacters(in: .whitespaces).uppercased()) }
            case "COUNT":
                if let n = Int(value), n > 0 { end = .count(n) }
            case "UNTIL":
                if let date = Self.parseUntil(value) { end = .until(date) }
            default:
                continue
            }
        }
        guard let frequency = freq else { return nil }
        return RecurrenceRule(
            frequency: frequency,
            interval: interval,
            daysOfWeek: days,
            end: end
        )
    }

    private static let untilFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    private static let untilDateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd"
        return f
    }()

    private static func formatUntil(_ date: Date) -> String {
        untilFormatter.string(from: date)
    }

    private static func parseUntil(_ raw: String) -> Date? {
        let upper = raw.uppercased()
        if let d = untilFormatter.date(from: upper) { return d }
        if let d = untilDateOnlyFormatter.date(from: upper) { return d }
        return nil
    }

    // MARK: - EventKit round-trip

    /// Builds an `EKRecurrenceRule` matching this Smoory rule. Two init paths: the
    /// simple 3-arg form for daily/monthly/yearly without BYDAY, and the full
    /// per-component form for weekly recurrence with day selection.
    func ekRule() -> EKRecurrenceRule {
        let ekEnd: EKRecurrenceEnd?
        switch end {
        case .never: ekEnd = nil
        case .count(let n): ekEnd = EKRecurrenceEnd(occurrenceCount: n)
        case .until(let date): ekEnd = EKRecurrenceEnd(end: date)
        }

        if frequency == .weekly, !daysOfWeek.isEmpty {
            let ekDays = daysOfWeek.map { EKRecurrenceDayOfWeek($0.ekWeekday) }
            return EKRecurrenceRule(
                recurrenceWith: frequency.ekFrequency,
                interval: max(1, interval),
                daysOfTheWeek: ekDays,
                daysOfTheMonth: nil,
                monthsOfTheYear: nil,
                weeksOfTheYear: nil,
                daysOfTheYear: nil,
                setPositions: nil,
                end: ekEnd
            )
        }
        return EKRecurrenceRule(
            recurrenceWith: frequency.ekFrequency,
            interval: max(1, interval),
            end: ekEnd
        )
    }

    // MARK: - Display

    /// Human-readable summary used in the item detail sheet's compact recurrence row.
    /// Examples: "Every day", "Every 2 weeks on Mon, Wed", "Monthly", "Yearly until Dec 31, 2026".
    var displayLabel: String {
        let base: String
        switch frequency {
        case .daily:
            base = interval == 1 ? "Every day" : "Every \(interval) days"
        case .weekly:
            if daysOfWeek.isEmpty {
                base = interval == 1 ? "Every week" : "Every \(interval) weeks"
            } else {
                let dayNames = daysOfWeek.map { Self.shortDayName($0) }.joined(separator: ", ")
                base = interval == 1
                    ? "Weekly on \(dayNames)"
                    : "Every \(interval) weeks on \(dayNames)"
            }
        case .monthly:
            base = interval == 1 ? "Monthly" : "Every \(interval) months"
        case .yearly:
            base = interval == 1 ? "Yearly" : "Every \(interval) years"
        }
        switch end {
        case .never: return base
        case .count(let n): return "\(base), \(n) times"
        case .until(let date):
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.locale = Locale.current
            return "\(base), until \(formatter.string(from: date))"
        }
    }

    private static func shortDayName(_ day: Weekday) -> String {
        switch day {
        case .monday: return "Mon"
        case .tuesday: return "Tue"
        case .wednesday: return "Wed"
        case .thursday: return "Thu"
        case .friday: return "Fri"
        case .saturday: return "Sat"
        case .sunday: return "Sun"
        }
    }
}

// MARK: - EKRecurrenceRule pull (extension keeps the synthesized memberwise init alive)

extension RecurrenceRule {
    /// Reads an `EKRecurrenceRule` back into a Smoory rule. Returns nil when EK exposes a
    /// frequency Smoory doesn't model (SECONDLY/MINUTELY/HOURLY) or when the rule shape
    /// uses fields we ignore — caller can choose to drop the Smoory-side rule rather than
    /// store a partial representation.
    init?(ek: EKRecurrenceRule) {
        guard let freq = Frequency(ek: ek.frequency) else { return nil }
        let resolvedDays: [Weekday] = (ek.daysOfTheWeek ?? []).compactMap {
            Weekday(ek: $0.dayOfTheWeek)
        }
        let resolvedEnd: End
        if let ekEnd = ek.recurrenceEnd {
            if ekEnd.occurrenceCount > 0 {
                resolvedEnd = .count(ekEnd.occurrenceCount)
            } else if ekEnd.endDate != nil {
                resolvedEnd = .until(ekEnd.endDate!)
            } else {
                resolvedEnd = .never
            }
        } else {
            resolvedEnd = .never
        }
        self.init(
            frequency: freq,
            interval: max(1, ek.interval),
            daysOfWeek: resolvedDays,
            end: resolvedEnd
        )
    }
}
