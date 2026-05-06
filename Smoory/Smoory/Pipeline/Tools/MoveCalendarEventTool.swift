import EventKit
import Foundation
import SwiftData
import SwiftUI

enum MoveCalendarEventTool: Tool {
    static let name = "move_calendar_event"

    static let description = """
        Move (reschedule) an existing calendar event. Use when the user asks to \
        change the time or date of an event they already have — "move tomorrow's \
        standup to 10am", "shift the dentist appointment to next Thursday".

        Pass `event_id` from a prior get_calendar_window result.

        For recurring events, choose `scope`:
        - "single": move only this one occurrence (default)
        - "following": move this one and every later occurrence
        - "all": move every occurrence in the series

        If `new_end` is omitted, the event's original duration is preserved.
        """

    static let confirmationTier: ConfirmationTier = .tier1Quick

    static let inputSchema = ToolInputSchema(
        properties: [
            "event_id": ToolInputSchemaProperty(
                type: "string",
                description: "EKEvent identifier from get_calendar_window."
            ),
            "new_start": ToolInputSchemaProperty(
                type: "string",
                description: "New start time. ISO 8601 preferred; natural-language phrases accepted."
            ),
            "new_end": ToolInputSchemaProperty(
                type: "string",
                description: "Optional new end time. If omitted, original duration preserved."
            ),
            "scope": ToolInputSchemaProperty(
                type: "string",
                description: "single | following | all. Default: single."
            )
        ],
        required: ["event_id", "new_start"]
    )

    struct Input: Codable {
        let event_id: String
        let new_start: String
        let new_end: String?
        let scope: String?
    }

    static func execute(parametersJSON: String, context: ToolExecutionContext) async throws -> ToolOutput {
        let input: Input
        do {
            input = try decodeInput(parametersJSON)
        } catch {
            return errorOutput(toolUseId: context.toolUseId, message: "could not decode parameters: \(error.localizedDescription)")
        }
        let scope = CalendarEventScope(rawValue: (input.scope ?? "single").lowercased()) ?? .single
        let calendarService = context.services.calendarService

        // Look up original to compute preserved end if new_end omitted.
        guard let original = (try? await calendarService.eventForIdentifier(input.event_id)) else {
            return errorOutput(toolUseId: context.toolUseId, message: "Event not found: \(input.event_id)")
        }

        let newStart: Date
        if let iso = parseISO8601(input.new_start) {
            newStart = iso
        } else {
            do {
                newStart = try await ScheduledActionTimeResolver.resolve(
                    input.new_start,
                    content: original.title ?? "",
                    services: context.services,
                    now: Date()
                )
            } catch {
                return errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
            }
        }

        let newEnd: Date
        if let endStr = input.new_end, !endStr.isEmpty {
            if let iso = parseISO8601(endStr) {
                newEnd = iso
            } else {
                do {
                    newEnd = try await ScheduledActionTimeResolver.resolve(
                        endStr,
                        content: original.title ?? "",
                        services: context.services,
                        now: newStart
                    )
                } catch {
                    return errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
                }
            }
        } else {
            let originalDuration = original.endDate.timeIntervalSince(original.startDate)
            newEnd = newStart.addingTimeInterval(originalDuration)
        }

        do {
            let event = try await calendarService.moveEvent(
                eventID: input.event_id,
                scope: scope,
                newStart: newStart,
                newEnd: newEnd
            )
            let payload: [String: any Sendable] = [
                "status": "moved",
                "id": event.eventIdentifier ?? input.event_id,
                "new_start": newStart.formatted(.iso8601),
                "new_end": newEnd.formatted(.iso8601),
                "scope": scope.rawValue
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
        let scope = (input.scope ?? "single").lowercased()
        let scopeBadge: String
        switch scope {
        case "all": scopeBadge = "All occurrences"
        case "following": scopeBadge = "This and following"
        default: scopeBadge = "Just this occurrence"
        }
        let timeStr = parseISO8601(input.new_start).map(formatHuman) ?? input.new_start
        return ProposedActionSummary(
            icon: "calendar.badge.clock",
            title: "Move event",
            primary: "→ \(timeStr)",
            secondary: scopeBadge
        )
    }

    @MainActor
    static func makeEditView(
        parametersJSON: String,
        modelContainer: ModelContainer,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) -> AnyView {
        // No edit view for v1 — confirm or decline. Move semantics + scope are
        // best surfaced as a clean confirm/decline; tweaking the time inline
        // would require us to know which scope to apply.
        AnyView(EmptyView())
    }

    // MARK: - Helpers (same shape as CreateCalendarEventTool)

    private static func decodeInput(_ jsonString: String) throws -> Input {
        guard let data = jsonString.data(using: .utf8), !data.isEmpty else {
            throw NSError(
                domain: "MoveCalendarEventTool",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "empty parameters"]
            )
        }
        return try JSONDecoder().decode(Input.self, from: data)
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
