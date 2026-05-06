import EventKit
import Foundation
import SwiftData
import SwiftUI

enum DeleteCalendarEventTool: Tool {
    static let name = "delete_calendar_event"

    static let description = """
        Delete a calendar event. Use when the user explicitly asks to remove or \
        cancel a scheduled event — "delete tomorrow's focus block", "cancel the \
        Friday standup".

        Pass `event_id` from a prior get_calendar_window result. For recurring \
        events choose `scope`:
        - "single": delete only this one occurrence (default)
        - "following": delete this one and every later occurrence
        - "all": delete every occurrence in the series

        Deletion can't be undone within Smoory — the user has to recreate the \
        event in Calendar.app if they change their mind. The confirmation card \
        surfaces this.
        """

    static let confirmationTier: ConfirmationTier = .tier2Review

    static let inputSchema = ToolInputSchema(
        properties: [
            "event_id": ToolInputSchemaProperty(
                type: "string",
                description: "EKEvent identifier from get_calendar_window."
            ),
            "scope": ToolInputSchemaProperty(
                type: "string",
                description: "single | following | all. Default: single."
            )
        ],
        required: ["event_id"]
    )

    struct Input: Codable {
        let event_id: String
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
        do {
            try await context.services.calendarService.deleteEvent(
                eventID: input.event_id,
                scope: scope
            )
            let payload: [String: any Sendable] = [
                "status": "deleted",
                "id": input.event_id,
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
        case "all": scopeBadge = "All occurrences (irreversible)"
        case "following": scopeBadge = "This and following (irreversible)"
        default: scopeBadge = "Just this occurrence (irreversible)"
        }
        return ProposedActionSummary(
            icon: "calendar.badge.minus",
            title: "Delete event",
            primary: input.event_id,
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
        // tier2Review: no edit view — confirm or decline only.
        AnyView(EmptyView())
    }

    // MARK: - Helpers

    private static func decodeInput(_ jsonString: String) throws -> Input {
        guard let data = jsonString.data(using: .utf8), !data.isEmpty else {
            throw NSError(
                domain: "DeleteCalendarEventTool",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "empty parameters"]
            )
        }
        return try JSONDecoder().decode(Input.self, from: data)
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
