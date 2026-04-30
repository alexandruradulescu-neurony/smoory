import Foundation
import SwiftData
import SwiftUI

enum CreateScheduledActionTool: Tool {
    static let name = "create_scheduled_action"

    static let description = """
        Create a reminder for the user. Use when the user asks to be reminded of \
        something at a specific time, like "remind me tomorrow at 2pm to call the \
        dentist" or "in 30 minutes, tell me to take the laundry out". The user sees \
        a confirmation card with the proposed reminder and resolved time before the \
        reminder is actually scheduled.

        Time format: prefer ISO 8601 (e.g., "2026-05-01T14:30:00"). Natural-language \
        relative phrases are also accepted — the tool resolves "tomorrow" → 9am, \
        "tonight" → 8pm, "this afternoon" → 2pm, "this evening" → 7pm, "this morning" \
        → next 9am. "In N minutes/hours/days", "today/tomorrow at HH:MM[am|pm]", \
        "noon", "midnight" all work. For times relative to calendar events, "30 \
        minutes before my dentist appointment" or "after my standup" — the tool looks \
        up the event by title substring.

        The reminder fires as a notification at the scheduled time, with the content \
        as the body. Reminders are one-off in v1 (no recurring user reminders yet).
        """

    static let confirmationTier: ConfirmationTier = .tier1Quick

    static let inputSchema = ToolInputSchema(
        properties: [
            "content": ToolInputSchemaProperty(
                type: "string",
                description: "The reminder text — what the user should be reminded of."
            ),
            "scheduled_for": ToolInputSchemaProperty(
                type: "string",
                description: "When to fire. ISO 8601 timestamp preferred; natural-language relative phrases also accepted."
            )
        ],
        required: ["content", "scheduled_for"]
    )

    struct Input: Codable {
        let content: String
        let scheduled_for: String
    }

    static func execute(parametersJSON: String, context: ToolExecutionContext) async throws -> ToolOutput {
        guard let service = context.services.scheduledActionService else {
            return errorOutput(toolUseId: context.toolUseId, message: "scheduled action service unavailable")
        }
        let input: Input
        do {
            input = try decodeInput(parametersJSON)
        } catch {
            return errorOutput(toolUseId: context.toolUseId, message: "could not decode parameters: \(error.localizedDescription)")
        }

        let resolved: Date
        do {
            resolved = try await resolveDate(input: input, services: context.services, now: Date())
        } catch let err as TimeResolverError {
            return errorOutput(toolUseId: context.toolUseId, message: String(describing: err))
        } catch {
            return errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }

        guard resolved > Date() else {
            return errorOutput(
                toolUseId: context.toolUseId,
                message: "scheduled time is in the past: \(resolved.formatted(.iso8601))"
            )
        }

        let action: ScheduledAction
        do {
            action = try await service.schedule(
                kind: .userReminder,
                at: resolved,
                content: input.content,
                recurringRule: nil,
                relatedEntityID: nil,
                source: .userChat
            )
        } catch {
            return errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }

        let payload: [String: any Sendable] = [
            "status": "scheduled",
            "id": action.id.uuidString,
            "content": action.content,
            "scheduled_for": action.scheduledFor.formatted(.iso8601)
        ]
        return ToolOutput(
            toolUseId: context.toolUseId,
            content: encodeJSON(payload),
            isError: false
        )
    }

    static func renderSummary(parametersJSON: String, modelContainer: ModelContainer) -> ProposedActionSummary? {
        guard let input = try? decodeInput(parametersJSON) else { return nil }
        let secondary: String
        if let iso = parseISO8601(input.scheduled_for) {
            secondary = formatHuman(iso)
        } else {
            secondary = formatNatural(input.scheduled_for)
        }
        return ProposedActionSummary(
            icon: "bell",
            title: "Set reminder",
            primary: input.content,
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
        AnyView(CreateScheduledActionEditView(
            parametersJSON: parametersJSON,
            onCommit: onCommit,
            onCancel: onCancel
        ))
    }

    // MARK: - Helpers

    static func decodeInput(_ jsonString: String) throws -> Input {
        guard let data = jsonString.data(using: .utf8), !data.isEmpty else {
            throw NSError(
                domain: "CreateScheduledActionTool",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "empty parameters"]
            )
        }
        return try JSONDecoder().decode(Input.self, from: data)
    }

    static func parseISO8601(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if let d = try? Date(trimmed, strategy: .iso8601) { return d }
        // Tolerate the LLM emitting "2026-05-01T14:30:00" without a timezone — interpret as local.
        let style = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
            .dateTimeSeparator(.standard).time(includingFractionalSeconds: false)
        if let d = try? style.parse(trimmed) { return d }
        return nil
    }

    private static func resolveDate(input: Input, services: ToolServices, now: Date) async throws -> Date {
        if let iso = parseISO8601(input.scheduled_for) { return iso }
        return try await ScheduledActionTimeResolver.resolve(
            input.scheduled_for,
            content: input.content,
            services: services,
            now: now
        )
    }

    private static func formatHuman(_ date: Date) -> String {
        let cal = Calendar.current
        let timeStr = date.formatted(.dateTime.hour().minute())
        if cal.isDateInToday(date)    { return "Today at \(timeStr)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow at \(timeStr)" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute())
    }

    /// Best-effort capitalization of a natural-language phrase the LLM passed.
    private static func formatNatural(_ phrase: String) -> String {
        let trimmed = phrase.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "(time will be resolved)" }
        return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
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
