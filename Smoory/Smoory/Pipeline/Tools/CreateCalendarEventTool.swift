import EventKit
import Foundation
import SwiftData
import SwiftUI

enum CreateCalendarEventTool: Tool {
    static let name = "create_calendar_event"

    static let description = """
        Create a new calendar event. Use when the user asks to schedule something \
        on their calendar — "schedule a 30-min focus block tomorrow at 2pm", \
        "add a meeting with Maria Friday at 10", "every weekday at 9am, 15-min \
        standup for the next month". The user sees a confirmation card with the \
        proposed event details (and any conflict warnings) before it's actually \
        saved.

        Time format: prefer ISO 8601 (e.g., "2026-05-01T14:30:00"). Natural-language \
        relative phrases also accepted — same resolver as create_scheduled_action.

        Provide either `end` (ISO/natural) OR `duration_minutes` (int), not both.
        Recurrence is optional — pass it only when the user explicitly asks for \
        a repeating event.

        Conflicts (overlapping events on non-muted calendars) are surfaced in the \
        confirmation card automatically — the user decides whether to keep the \
        proposal anyway. You don't need to call get_calendar_window first.
        """

    static let confirmationTier: ConfirmationTier = .tier1Quick

    static let inputSchema = ToolInputSchema(
        properties: [
            "title": ToolInputSchemaProperty(
                type: "string",
                description: "Event title."
            ),
            "start": ToolInputSchemaProperty(
                type: "string",
                description: "When the event starts. ISO 8601 preferred; natural-language phrases accepted."
            ),
            "end": ToolInputSchemaProperty(
                type: "string",
                description: "When the event ends. ISO/natural. Provide either end OR duration_minutes."
            ),
            "duration_minutes": ToolInputSchemaProperty(
                type: "integer",
                description: "Alternative to `end`: minutes from start. Provide either end OR duration_minutes."
            ),
            "location": ToolInputSchemaProperty(
                type: "string",
                description: "Optional location."
            ),
            "notes": ToolInputSchemaProperty(
                type: "string",
                description: "Optional notes / description body for the event."
            ),
            "is_all_day": ToolInputSchemaProperty(
                type: "boolean",
                description: "When true, the start/end are treated as date boundaries; default false."
            ),
            "recurrence": ToolInputSchemaProperty(
                type: "object",
                description: "Optional recurrence. Object with keys: frequency (DAILY|WEEKLY|MONTHLY|YEARLY), interval (int, default 1), days_of_week (array of MO/TU/WE/TH/FR/SA/SU, only for WEEKLY), end (object with `count: int` OR `until: ISO8601`)."
            )
        ],
        required: ["title", "start"]
    )

    struct Input: Codable {
        let title: String
        let start: String
        let end: String?
        let duration_minutes: Int?
        let location: String?
        let notes: String?
        let is_all_day: Bool?
        let recurrence: RecurrenceInput?
    }

    struct RecurrenceInput: Codable {
        let frequency: String
        let interval: Int?
        let days_of_week: [String]?
        let end: RecurrenceEndInput?
    }

    struct RecurrenceEndInput: Codable {
        let count: Int?
        let until: String?
    }

    static func execute(parametersJSON: String, context: ToolExecutionContext) async throws -> ToolOutput {
        let input: Input
        do {
            input = try decodeInput(parametersJSON)
        } catch {
            return errorOutput(toolUseId: context.toolUseId, message: "could not decode parameters: \(error.localizedDescription)")
        }

        let resolved: (start: Date, end: Date)
        do {
            resolved = try await resolveTimes(input: input, services: context.services)
        } catch {
            return errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }

        let recurrence = buildEKRecurrence(from: input.recurrence)

        let createInput = CalendarService.CreateEventInput(
            title: input.title,
            start: resolved.start,
            end: resolved.end,
            isAllDay: input.is_all_day ?? false,
            location: input.location,
            notes: input.notes,
            recurrence: recurrence
        )

        do {
            let event = try await context.services.calendarService.createEvent(createInput)
            let conflicts = (try? await context.services.calendarService.findConflicts(
                start: resolved.start,
                end: resolved.end,
                excludingEventID: event.eventIdentifier
            )) ?? []
            let payload: [String: any Sendable] = [
                "status": "created",
                "id": event.eventIdentifier ?? "",
                "calendar_name": event.calendar.title,
                "conflicts": conflicts.map { ["title": $0.title, "start": $0.start.formatted(.iso8601), "end": $0.end.formatted(.iso8601)] }
            ]
            return ToolOutput(
                toolUseId: context.toolUseId,
                content: encodeJSON(payload),
                isError: false
            )
        } catch {
            return errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }
    }

    static func renderSummary(parametersJSON: String, modelContainer: ModelContainer) -> ProposedActionSummary? {
        guard let input = try? decodeInput(parametersJSON) else { return nil }
        let timeStr: String
        if let iso = parseISO8601(input.start) {
            timeStr = formatHuman(iso)
        } else {
            timeStr = input.start
        }
        var secondary = "Calendar event"
        if let recurrence = input.recurrence {
            secondary += " · \(displayRecurrence(recurrence))"
        }
        return ProposedActionSummary(
            icon: "calendar.badge.plus",
            title: "Create event",
            primary: "\(input.title) — \(timeStr)",
            secondary: secondary
        )
    }

    @MainActor
    static func makeEditView(
        parametersJSON: String,
        modelContainer: ModelContainer,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) -> AnyView {
        AnyView(CreateCalendarEventEditView(
            parametersJSON: parametersJSON,
            onCommit: onCommit,
            onCancel: onCancel
        ))
    }

    // MARK: - Helpers

    private static func decodeInput(_ jsonString: String) throws -> Input {
        guard let data = jsonString.data(using: .utf8), !data.isEmpty else {
            throw NSError(
                domain: "CreateCalendarEventTool",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "empty parameters"]
            )
        }
        return try JSONDecoder().decode(Input.self, from: data)
    }

    private static func resolveTimes(input: Input, services: ToolServices) async throws -> (start: Date, end: Date) {
        let start: Date
        if let iso = parseISO8601(input.start) {
            start = iso
        } else {
            start = try await ScheduledActionTimeResolver.resolve(
                input.start,
                content: input.title,
                services: services,
                now: Date()
            )
        }

        let end: Date
        if let endStr = input.end, !endStr.isEmpty {
            if let iso = parseISO8601(endStr) {
                end = iso
            } else {
                end = try await ScheduledActionTimeResolver.resolve(
                    endStr,
                    content: input.title,
                    services: services,
                    now: start
                )
            }
        } else if let minutes = input.duration_minutes, minutes > 0 {
            end = start.addingTimeInterval(TimeInterval(minutes * 60))
        } else {
            // Default: 30-minute event when neither end nor duration is provided.
            end = start.addingTimeInterval(30 * 60)
        }

        guard end > start else {
            throw NSError(
                domain: "CreateCalendarEventTool",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Event end must be after start (got \(end.formatted(.iso8601)) ≤ \(start.formatted(.iso8601)))"]
            )
        }
        return (start, end)
    }

    private static func buildEKRecurrence(from input: RecurrenceInput?) -> EKRecurrenceRule? {
        guard let input else { return nil }
        guard let freq = RecurrenceRule.Frequency(rawValue: input.frequency.uppercased()) else { return nil }
        let interval = max(1, input.interval ?? 1)
        let days: [RecurrenceRule.Weekday] = (input.days_of_week ?? [])
            .compactMap { RecurrenceRule.Weekday(rawValue: $0.uppercased()) }
        let end: RecurrenceRule.End
        if let endInput = input.end {
            if let count = endInput.count, count > 0 {
                end = .count(count)
            } else if let untilStr = endInput.until, let untilDate = parseISO8601(untilStr) {
                end = .until(untilDate)
            } else {
                end = .never
            }
        } else {
            end = .never
        }
        let rule = RecurrenceRule(
            frequency: freq,
            interval: interval,
            daysOfWeek: days,
            end: end
        )
        return rule.ekRule()
    }

    private static func displayRecurrence(_ input: RecurrenceInput) -> String {
        guard let freq = RecurrenceRule.Frequency(rawValue: input.frequency.uppercased()) else {
            return "recurring"
        }
        let interval = max(1, input.interval ?? 1)
        let days = (input.days_of_week ?? []).compactMap { RecurrenceRule.Weekday(rawValue: $0.uppercased()) }
        let end: RecurrenceRule.End
        if let endInput = input.end {
            if let count = endInput.count, count > 0 {
                end = .count(count)
            } else if let untilStr = endInput.until, let untilDate = parseISO8601(untilStr) {
                end = .until(untilDate)
            } else {
                end = .never
            }
        } else {
            end = .never
        }
        return RecurrenceRule(
            frequency: freq,
            interval: interval,
            daysOfWeek: days,
            end: end
        ).displayLabel
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if let d = try? Date(trimmed, strategy: .iso8601) { return d }
        let style = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
            .dateTimeSeparator(.standard).time(includingFractionalSeconds: false)
        if let d = try? style.parse(trimmed) { return d }
        return nil
    }

    private static func formatHuman(_ date: Date) -> String {
        let cal = Calendar.current
        let timeStr = date.formatted(.dateTime.hour().minute())
        if cal.isDateInToday(date)    { return "Today at \(timeStr)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow at \(timeStr)" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute())
    }

    private static func encodeJSON(_ obj: [String: any Sendable]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }

    private static func errorOutput(toolUseId: String, message: String) -> ToolOutput {
        let payload = #"{"status":"error","message":"\#(escape(message))"}"#
        return ToolOutput(toolUseId: toolUseId, content: payload, isError: true)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Edit view

private struct CreateCalendarEventEditView: View {
    let parametersJSON: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var title: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var allDay: Bool

    init(
        parametersJSON: String,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.parametersJSON = parametersJSON
        self.onCommit = onCommit
        self.onCancel = onCancel
        let decoded = try? JSONDecoder().decode(CreateCalendarEventTool.Input.self, from: Data(parametersJSON.utf8))
        let now = Date()
        let parsedStart: Date = decoded.flatMap { Self.parseISO8601($0.start) } ?? now
        let parsedEnd: Date = decoded.flatMap { $0.end.flatMap(Self.parseISO8601) } ?? parsedStart.addingTimeInterval(30 * 60)
        _title = State(initialValue: decoded?.title ?? "")
        _startDate = State(initialValue: parsedStart)
        _endDate = State(initialValue: parsedEnd)
        _allDay = State(initialValue: decoded?.is_all_day ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit event").font(.headline)
            Form {
                TextField("Title", text: $title)
                Toggle("All-day", isOn: $allDay)
                DatePicker("Starts", selection: $startDate, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                DatePicker("Ends", selection: $endDate, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
            }
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || endDate <= startDate)
            }
        }
        .padding(14)
        .frame(minWidth: 360)
    }

    private func commit() {
        // Reconstruct an Input JSON from edited values, preserving optional fields
        // we don't expose in the editor (location/notes/recurrence) by passing
        // through from the original parametersJSON.
        let original = try? JSONDecoder().decode(CreateCalendarEventTool.Input.self, from: Data(parametersJSON.utf8))
        let edited = CreateCalendarEventTool.Input(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            start: startDate.formatted(.iso8601),
            end: endDate.formatted(.iso8601),
            duration_minutes: nil,
            location: original?.location,
            notes: original?.notes,
            is_all_day: allDay,
            recurrence: original?.recurrence
        )
        guard let data = try? JSONEncoder().encode(edited),
              let json = String(data: data, encoding: .utf8) else { return }
        onCommit(json)
    }

    private static func parseISO8601(_ s: String) -> Date? {
        if let d = try? Date(s, strategy: .iso8601) { return d }
        let style = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
            .dateTimeSeparator(.standard).time(includingFractionalSeconds: false)
        return try? style.parse(s)
    }
}
