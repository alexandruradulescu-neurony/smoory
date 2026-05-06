import Foundation

enum GetCalendarWindowTool: Tool {
    static let name = "get_calendar_window"

    static let description = """
        Get the user's calendar events for a date range. Use this when the user asks about \
        meetings, events, or what's on their calendar. The default range is the current rolling \
        window (today to +2 days depending on time of day).
        """

    static let inputSchema = ToolInputSchema(
        properties: [
            "start": ToolInputSchemaProperty(
                type: "string",
                description: "Start date (ISO 8601, optional)"
            ),
            "end": ToolInputSchemaProperty(
                type: "string",
                description: "End date (ISO 8601, optional)"
            ),
        ],
        required: []
    )

    static let confirmationTier: ConfirmationTier = .silent

    private struct Input: Decodable {
        let start: String?
        let end: String?
    }

    private struct EventPayload: Encodable {
        let id: String             // EKEvent.eventIdentifier — required by move/delete tools
        let title: String
        let start: String          // ISO 8601 with local timezone offset
        let end: String
        let location: String?
        let isAllDay: Bool
        let calendarName: String
        let notes: String?         // event description / meeting body — Zoom/Meet links live here
        let url: String?           // optional event URL — sometimes the meeting link itself
    }

    /// ISO 8601 in the user's local timezone so wall-clock times round-trip the LLM
    /// unchanged. Default `.iso8601` style emits UTC with a "Z" suffix, which the
    /// chat model then parrots verbatim — making 08:00 local read back as 05:00 in
    /// EEST. Including the +HH:MM offset removes the ambiguity.
    private static let localISO = Date.ISO8601FormatStyle(timeZone: .current)

    static func execute(
        parametersJSON: String,
        context: ToolExecutionContext
    ) async throws -> ToolOutput {
        let input = try Self.decodeInput(parametersJSON)
        let calendar = context.services.calendarService

        let window = try await calendar.eventsForCurrentWindow()
        let allEvents = window.days.flatMap(\.events)

        let parsedStart = input.start.flatMap { try? Date($0, strategy: .iso8601) }
        let parsedEnd = input.end.flatMap { try? Date($0, strategy: .iso8601) }

        let filtered: [CalendarEvent]
        switch (parsedStart, parsedEnd) {
        case (let s?, let e?):
            filtered = allEvents.filter { $0.start < e && $0.end > s }
        case (let s?, nil):
            filtered = allEvents.filter { $0.end > s }
        case (nil, let e?):
            filtered = allEvents.filter { $0.start < e }
        case (nil, nil):
            filtered = allEvents
        }

        let payload = filtered.map { event in
            EventPayload(
                id: event.id,
                title: event.title,
                start: event.start.formatted(Self.localISO),
                end: event.end.formatted(Self.localISO),
                location: event.location,
                isAllDay: event.isAllDay,
                calendarName: event.calendarName,
                notes: event.notes,
                url: event.url?.absoluteString
            )
        }

        let json = try Self.encodeJSON(payload)
        return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
    }

    private static func decodeInput(_ jsonString: String) throws -> Input {
        let trimmed = jsonString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return Input(start: nil, end: nil)
        }
        return (try? JSONDecoder().decode(Input.self, from: data)) ?? Input(start: nil, end: nil)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
