import Foundation
import SwiftData

enum GetActiveGoalsTool: Tool {
    static let name = "get_active_goals"

    static let description = """
        List the user's currently active goals. Use this to understand what the user is \
        working toward when they ask about goals, progress, or what matters.
        """

    static let inputSchema = ToolInputSchema(
        properties: [
            "role": ToolInputSchemaProperty(
                type: "string",
                description: "Optional role slug to filter"
            ),
        ],
        required: []
    )

    static let confirmationTier: ConfirmationTier = .silent

    private struct Input: Decodable {
        let role: String?
    }

    private struct GoalPayload: Encodable {
        let title: String
        let details: String
        let status: String
        let goalType: String
        let targetDate: String?
        let role: String?
    }

    static func execute(
        parametersJSON: String,
        context: ToolExecutionContext
    ) async throws -> ToolOutput {
        let input = try Self.decodeInput(parametersJSON)
        let modelContext = ModelContext(context.services.modelContainer)

        // Fetch all goals, filter to active in Swift. SwiftData #Predicate on Int-backed
        // enum-stored attributes is finicky on macOS 14; fetch-and-filter is robust.
        var descriptor = FetchDescriptor<Goal>()
        descriptor.fetchLimit = 200
        let allGoals = (try? modelContext.fetch(descriptor)) ?? []

        var filtered = allGoals.filter { $0.status == .active }
        if let roleSlug = input.role {
            filtered = filtered.filter { $0.role?.slug == roleSlug }
        }

        let payload = filtered.map { goal in
            GoalPayload(
                title: goal.title,
                details: goal.details,
                status: Self.statusName(goal.status),
                goalType: Self.goalTypeName(goal.goalType),
                targetDate: goal.targetDate?.formatted(.iso8601),
                role: goal.role?.slug
            )
        }

        let json = try Self.encodeJSON(payload)
        return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
    }

    private static func decodeInput(_ jsonString: String) throws -> Input {
        let trimmed = jsonString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return Input(role: nil)
        }
        return (try? JSONDecoder().decode(Input.self, from: data)) ?? Input(role: nil)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func statusName(_ status: GoalStatus) -> String {
        switch status {
        case .active: return "active"
        case .paused: return "paused"
        case .achieved: return "achieved"
        case .dropped: return "dropped"
        }
    }

    private static func goalTypeName(_ type: GoalType) -> String {
        switch type {
        case .tracked: return "tracked"
        case .reflective: return "reflective"
        case .both: return "both"
        }
    }
}
