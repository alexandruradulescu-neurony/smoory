import Foundation

enum TimeResolverError: Error, CustomStringConvertible {
    case unparseable(String)
    case missingCalendarEvent(needle: String)

    var description: String {
        switch self {
        case .unparseable(let s):
            return "could not parse time phrase: \"\(s)\""
        case .missingCalendarEvent(let needle):
            return "no calendar event matches \"\(needle)\" in the next 3 days"
        }
    }
}

/// Resolves a small set of natural-language time phrases to concrete Date values.
/// Not a general-purpose date parser — covers ~95% of casual reminder phrases that
/// the LLM might pass instead of ISO 8601. Order of patterns matters: keywords
/// (tonight/tomorrow/this morning) match first, then "in N <unit>", then
/// "today/tomorrow at <time>", then "before/after my <event>".
enum ScheduledActionTimeResolver {
    static func resolve(
        _ phrase: String,
        content: String,
        services: ToolServices,
        now: Date,
        calendar: Calendar = .current
    ) async throws -> Date {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { throw TimeResolverError.unparseable(phrase) }

        if let date = resolveKeyword(trimmed, now: now, calendar: calendar) {
            return date
        }
        if let date = resolveRelativeOffset(trimmed, now: now) {
            return date
        }
        if let date = resolveAtTimeOfDay(trimmed, now: now, calendar: calendar) {
            return date
        }
        if let date = try await resolveCalendarRelative(
            trimmed, services: services, calendar: calendar
        ) {
            return date
        }

        throw TimeResolverError.unparseable(phrase)
    }

    // MARK: - 1. Keywords

    private static func resolveKeyword(_ phrase: String, now: Date, calendar: Calendar) -> Date? {
        switch phrase {
        case "tonight":
            return atHour(20, on: now, calendar: calendar)
        case "tomorrow":
            return atHour(9, on: tomorrow(of: now, calendar: calendar), calendar: calendar)
        case "this morning":
            // 8:55 AM → today 9am (still upcoming). 9:01 AM → tomorrow 9am.
            let today9 = atHour(9, on: now, calendar: calendar)
            return today9 > now
                ? today9
                : atHour(9, on: tomorrow(of: now, calendar: calendar), calendar: calendar)
        case "this afternoon":
            return atHour(14, on: now, calendar: calendar)
        case "this evening":
            return atHour(19, on: now, calendar: calendar)
        case "noon":
            return atHour(12, on: now, calendar: calendar)
        case "midnight":
            return atHour(0, on: tomorrow(of: now, calendar: calendar), calendar: calendar)
        default:
            return nil
        }
    }

    // MARK: - 2. "in N <unit>"

    private static let offsetRegex = /^in\s+(\d+)\s+(minute|minutes|min|mins|hour|hours|hr|hrs|day|days)$/

    private static func resolveRelativeOffset(_ phrase: String, now: Date) -> Date? {
        guard let match = try? offsetRegex.wholeMatch(in: phrase) else { return nil }
        let value = Int(match.1) ?? 0
        let unit = String(match.2)
        let secondsPerUnit: TimeInterval
        switch unit {
        case "minute", "minutes", "min", "mins": secondsPerUnit = 60
        case "hour", "hours", "hr", "hrs":       secondsPerUnit = 3600
        case "day", "days":                       secondsPerUnit = 86_400
        default: return nil
        }
        return now.addingTimeInterval(TimeInterval(value) * secondsPerUnit)
    }

    // MARK: - 3. "today/tomorrow at <time>"

    private static let atTimeRegex = /^(today|tomorrow)\s+at\s+(noon|midnight|\d{1,2}(?::\d{2})?\s*(?:am|pm)?)$/

    private static func resolveAtTimeOfDay(_ phrase: String, now: Date, calendar: Calendar) -> Date? {
        guard let match = try? atTimeRegex.wholeMatch(in: phrase) else { return nil }
        let dayWord = String(match.1)
        let timeStr = String(match.2).trimmingCharacters(in: .whitespaces)

        let baseDay = (dayWord == "tomorrow") ? tomorrow(of: now, calendar: calendar) : now

        let (hour, minute): (Int, Int)
        if timeStr == "noon"            { (hour, minute) = (12, 0) }
        else if timeStr == "midnight"   { (hour, minute) = (0, 0) }
        else if let parsed = parseHourMinute(timeStr) { (hour, minute) = parsed }
        else { return nil }

        var comps = calendar.dateComponents([.year, .month, .day], from: baseDay)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return calendar.date(from: comps)
    }

    /// "3pm" → (15, 0); "14:30" → (14, 30); "9 am" → (9, 0); "12 pm" → (12, 0); "12 am" → (0, 0).
    private static let hourMinuteRegex = /^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$/

    private static func parseHourMinute(_ s: String) -> (Int, Int)? {
        guard let m = try? hourMinuteRegex.wholeMatch(in: s) else { return nil }
        var hour = Int(m.1) ?? 0
        let minute = m.2.flatMap { Int($0) } ?? 0
        let suffix = m.3.map(String.init)
        if minute < 0 || minute > 59 { return nil }
        if let suffix {
            if hour < 1 || hour > 12 { return nil }
            if suffix == "pm" && hour != 12 { hour += 12 }
            if suffix == "am" && hour == 12 { hour = 0 }
        } else {
            if hour < 0 || hour > 23 { return nil }
        }
        return (hour, minute)
    }

    // MARK: - 4. "before/after my <event>"

    private static let beforeRegex = /^(\d+\s+(?:minute|minutes|min|mins|hour|hours|hr|hrs)\s+)?before\s+my\s+(.+)$/
    private static let afterRegex  = /^(\d+\s+(?:minute|minutes|min|mins|hour|hours|hr|hrs)\s+)?after\s+my\s+(.+)$/

    private static func resolveCalendarRelative(
        _ phrase: String,
        services: ToolServices,
        calendar: Calendar
    ) async throws -> Date? {
        let isBefore: Bool
        let needle: String
        let leadString: String?
        if let m = try? beforeRegex.wholeMatch(in: phrase) {
            isBefore = true
            leadString = m.1.map(String.init)
            needle = String(m.2).trimmingCharacters(in: .whitespaces)
        } else if let m = try? afterRegex.wholeMatch(in: phrase) {
            isBefore = false
            leadString = m.1.map(String.init)
            needle = String(m.2).trimmingCharacters(in: .whitespaces)
        } else {
            return nil
        }

        let leadSeconds: TimeInterval = leadString.flatMap(parseLead) ?? (isBefore ? 1800 : 900)

        let window = try await services.calendarService.eventsForCurrentWindow()
        let allEvents = window.days.flatMap(\.events).sorted { $0.start < $1.start }
        guard let event = allEvents.first(where: { $0.title.lowercased().contains(needle) }) else {
            throw TimeResolverError.missingCalendarEvent(needle: needle)
        }
        return isBefore
            ? event.start.addingTimeInterval(-leadSeconds)
            : event.end.addingTimeInterval(leadSeconds)
    }

    private static let leadRegex = /^(\d+)\s+(minute|minutes|min|mins|hour|hours|hr|hrs)/

    private static func parseLead(_ s: String) -> TimeInterval? {
        guard let m = try? leadRegex.firstMatch(in: s) else { return nil }
        let n = Double(m.1) ?? 0
        let unit = String(m.2)
        if unit.hasPrefix("min") { return n * 60 }
        return n * 3600
    }

    // MARK: - Helpers

    private static func atHour(_ hour: Int, on day: Date, calendar: Calendar) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: day)
        comps.hour = hour
        comps.minute = 0
        comps.second = 0
        return calendar.date(from: comps) ?? day
    }

    private static func tomorrow(of now: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: now) ?? now
    }
}
