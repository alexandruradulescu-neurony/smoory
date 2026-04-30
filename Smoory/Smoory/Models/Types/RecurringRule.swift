import Foundation

/// Per-occurrence recurrence rule for a ScheduledAction. Stored on the model as a
/// JSON string (`recurringRuleJSON`); never @Model itself. Use `RecurringRule.encode`
/// / `decode` to round-trip.
struct RecurringRule: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable, Hashable {
        case daily
        case weekly
        case weekdays
        case none
    }

    let kind: Kind
    /// Hour + minute carry the wall-clock time-of-day. Other components ignored.
    let timeOfDay: DateComponents
    /// 1=Sunday … 7=Saturday for `.weekly`; nil otherwise.
    let dayOfWeek: Int?

    static func encode(_ rule: RecurringRule?) -> String? {
        guard let rule else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(rule)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decode(_ json: String?) -> RecurringRule? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecurringRule.self, from: data)
    }
}
