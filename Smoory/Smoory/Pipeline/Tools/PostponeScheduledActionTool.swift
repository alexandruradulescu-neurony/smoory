import Foundation

enum PostponeScheduledActionTool: Tool {
    static let name = "postpone_scheduled_action"

    static let description = """
        Postpone a scheduled action (day review, reminder, etc.) to a later time. Use \
        when the user wants to defer a Smoory-scheduled prompt: "let's talk in two hours", \
        "remind me at 9 instead of 8", "not now, push it back". Provide either by_minutes \
        (relative push) or new_time (specific ISO 8601 timestamp), not both.
        """

    static let confirmationTier: ConfirmationTier = .silent

    static let inputSchema = ToolInputSchema(
        properties: [
            "action_id": ToolInputSchemaProperty(
                type: "string",
                description: "UUID of the scheduled action to postpone."
            ),
            "by_minutes": ToolInputSchemaProperty(
                type: "integer",
                description: "Minutes to push the action later. Provide this OR new_time, not both."
            ),
            "new_time": ToolInputSchemaProperty(
                type: "string",
                description: "ISO 8601 timestamp for the new scheduled time. Provide this OR by_minutes, not both."
            ),
            "reason": ToolInputSchemaProperty(
                type: "string",
                description: "Optional reason given by the user."
            )
        ],
        required: ["action_id"]
    )

    private struct Input: Decodable {
        let action_id: String
        let by_minutes: Int?
        let new_time: String?
        let reason: String?
    }

    static func execute(parametersJSON: String, context: ToolExecutionContext) async throws -> ToolOutput {
        let input = try decodeInput(parametersJSON)

        guard let service = context.services.scheduledActionService else {
            return errorOutput(toolUseId: context.toolUseId, message: "scheduled action service unavailable")
        }
        guard let actionID = UUID(uuidString: input.action_id) else {
            return errorOutput(toolUseId: context.toolUseId, message: "invalid action_id (not a UUID)")
        }

        let updated: ScheduledAction
        do {
            switch (input.by_minutes, input.new_time) {
            case let (minutes?, nil):
                updated = try await service.postpone(
                    actionID: actionID,
                    by: TimeInterval(minutes * 60),
                    reason: input.reason
                )
            case let (nil, isoString?):
                guard let parsed = try? Date(isoString, strategy: .iso8601) else {
                    return errorOutput(toolUseId: context.toolUseId, message: "could not parse new_time as ISO 8601")
                }
                updated = try await service.reschedule(
                    actionID: actionID,
                    to: parsed,
                    reason: input.reason
                )
            case (nil, nil):
                return errorOutput(
                    toolUseId: context.toolUseId,
                    message: "specify either by_minutes or new_time"
                )
            case (.some, .some):
                return errorOutput(
                    toolUseId: context.toolUseId,
                    message: "specify only one of by_minutes or new_time"
                )
            }
        } catch {
            return errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }

        let payload: [String: any Sendable] = [
            "status": "postponed",
            "action_id": updated.id.uuidString,
            "scheduled_for": updated.scheduledFor.formatted(.iso8601),
            "deferral_count": updated.deferralCount
        ]
        return ToolOutput(
            toolUseId: context.toolUseId,
            content: encodeJSON(payload),
            isError: false
        )
    }

    private static func decodeInput(_ jsonString: String) throws -> Input {
        guard let data = jsonString.data(using: .utf8), !data.isEmpty else {
            throw NSError(
                domain: "PostponeScheduledActionTool",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "empty parameters"]
            )
        }
        return try JSONDecoder().decode(Input.self, from: data)
    }

    private static func errorOutput(toolUseId: String, message: String) -> ToolOutput {
        let payload = #"{"status":"error","message":"\#(escape(message))"}"#
        return ToolOutput(toolUseId: toolUseId, content: payload, isError: true)
    }

    private static func encodeJSON(_ obj: [String: any Sendable]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
