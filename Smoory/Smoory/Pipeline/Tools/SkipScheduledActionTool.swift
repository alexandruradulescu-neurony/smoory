import Foundation

enum SkipScheduledActionTool: Tool {
    static let name = "skip_scheduled_action"

    static let description = """
        Skip the current occurrence of a scheduled action without affecting future \
        occurrences of recurring schedules. Use when the user wants to skip just this \
        one ("let's skip the day review tonight, I'm tired"). For recurring actions, \
        the next occurrence still happens as scheduled.
        """

    static let confirmationTier: ConfirmationTier = .silent

    static let inputSchema = ToolInputSchema(
        properties: [
            "action_id": ToolInputSchemaProperty(
                type: "string",
                description: "UUID of the scheduled action to skip."
            )
        ],
        required: ["action_id"]
    )

    private struct Input: Decodable { let action_id: String }

    static func execute(parametersJSON: String, context: ToolExecutionContext) async throws -> ToolOutput {
        let input = try decodeInput(parametersJSON)

        guard let service = context.services.scheduledActionService else {
            return errorOutput(toolUseId: context.toolUseId, message: "scheduled action service unavailable")
        }
        guard let actionID = UUID(uuidString: input.action_id) else {
            return errorOutput(toolUseId: context.toolUseId, message: "invalid action_id (not a UUID)")
        }

        do {
            try await service.skipThisOccurrence(actionID: actionID)
        } catch {
            return errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }

        let payload = #"{"status":"skipped","action_id":"\#(actionID.uuidString)"}"#
        return ToolOutput(toolUseId: context.toolUseId, content: payload, isError: false)
    }

    private static func decodeInput(_ jsonString: String) throws -> Input {
        guard let data = jsonString.data(using: .utf8), !data.isEmpty else {
            throw NSError(
                domain: "SkipScheduledActionTool",
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

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
