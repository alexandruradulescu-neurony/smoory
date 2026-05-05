import Foundation

enum GetMyScheduledActionsTool: Tool {
    static let name = "get_my_scheduled_actions"

    static let description = """
        List the user's pending scheduled actions (reminders, day reviews, etc.). \
        Use when the user asks about what's scheduled, what reminders they have, or \
        what's coming up. By default returns user-created reminders only — set \
        include_system to true if the user wants to see system-scheduled actions \
        like day reviews too.
        """

    static let confirmationTier: ConfirmationTier = .silent

    static let inputSchema = ToolInputSchema(
        properties: [
            "include_system": ToolInputSchemaProperty(
                type: "boolean",
                description: "Include system-scheduled actions (day_review, week_review, morning_brief, goal_nudge). Default false."
            ),
            "limit": ToolInputSchemaProperty(
                type: "integer",
                description: "Max results (default 20, capped at 50)."
            )
        ],
        required: []
    )

    private struct Input: Decodable {
        let include_system: Bool?
        let limit: Int?
    }

    private struct ActionPayload: Encodable {
        let id: String
        let kind: String
        let content: String
        let scheduledFor: String
        let createdBySource: String
    }

    static func execute(parametersJSON: String, context: ToolExecutionContext) async throws -> ToolOutput {
        guard let service = context.services.scheduledActionService else {
            return errorOutput(toolUseId: context.toolUseId, message: "scheduled action service unavailable")
        }
        let input = (try? decodeInput(parametersJSON)) ?? Input(include_system: nil, limit: nil)
        let includeSystem = input.include_system ?? false
        let limit = max(1, min(input.limit ?? 20, 50))

        let actions: [ScheduledAction]
        do {
            // ScheduledActionService is @MainActor; tool.execute is nonisolated async.
            actions = try await MainActor.run {
                try service.pendingActions(within: 30 * 86_400)
            }
        } catch {
            return errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }

        let filtered = actions
            .filter { includeSystem ? true : ($0.createdBySource == .userChat) }
            .prefix(limit)

        let payload = filtered.map { action in
            ActionPayload(
                id: action.id.uuidString,
                kind: kindLabel(for: action.kind),
                content: action.content,
                scheduledFor: action.scheduledFor.formatted(.iso8601),
                createdBySource: action.createdBySource == .userChat ? "user_chat" : "system"
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(Array(payload))) ?? Data("[]".utf8)
        let json = String(data: data, encoding: .utf8) ?? "[]"

        return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
    }

    private static func kindLabel(for kind: ScheduledActionKind) -> String {
        switch kind {
        case .morningBrief: return "morning_brief"
        case .dayReview:    return "day_review"
        case .weekReview:   return "week_review"
        case .goalNudge:    return "goal_nudge"
        case .userReminder: return "reminder"
        case .endOfDay:     return "end_of_day"
        }
    }

    private static func decodeInput(_ jsonString: String) throws -> Input {
        guard let data = jsonString.data(using: .utf8), !data.isEmpty else {
            return Input(include_system: nil, limit: nil)
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
