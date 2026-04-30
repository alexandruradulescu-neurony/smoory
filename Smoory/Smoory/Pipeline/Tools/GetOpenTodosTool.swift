import Foundation
import SwiftData

enum GetOpenTodosTool: Tool {
    static let name = "get_open_todos"

    static let description = """
        List the user's open todos with optional filters by due date, role, or priority. \
        Use this when the user asks about tasks, what's pending, or what needs to be done.
        """

    static let inputSchema = ToolInputSchema(
        properties: [
            "role": ToolInputSchemaProperty(
                type: "string",
                description: "Optional role slug to filter"
            ),
            "due_before": ToolInputSchemaProperty(
                type: "string",
                description: "ISO date — only todos due before this"
            ),
            "priority_min": ToolInputSchemaProperty(
                type: "string",
                description: "low | normal | high | urgent"
            ),
            "limit": ToolInputSchemaProperty(
                type: "integer",
                description: "Max items to return (default 20)"
            ),
        ],
        required: []
    )

    static let confirmationTier: ConfirmationTier = .silent

    private struct Input: Decodable {
        let role: String?
        let dueBefore: String?
        let priorityMin: String?
        let limit: Int?

        enum CodingKeys: String, CodingKey {
            case role
            case dueBefore = "due_before"
            case priorityMin = "priority_min"
            case limit
        }
    }

    private struct TodoPayload: Encodable {
        let title: String
        let notes: String
        let dueDate: String?
        let priority: String
        let role: String?
        let project: String?
    }

    static func execute(
        parametersJSON: String,
        context: ToolExecutionContext
    ) async throws -> ToolOutput {
        let input = try Self.decodeInput(parametersJSON)
        let modelContext = ModelContext(context.services.modelContainer)

        var descriptor = FetchDescriptor<Todo>()
        descriptor.fetchLimit = 500
        let allTodos = (try? modelContext.fetch(descriptor)) ?? []

        // Top-level only: subtasks must not leak into chat replies as flat items.
        var filtered = allTodos.filter { !$0.isCompleted && $0.parentTodo == nil }

        if let roleSlug = input.role {
            filtered = filtered.filter { $0.role?.slug == roleSlug }
        }

        if let dueBeforeStr = input.dueBefore,
           let dueBefore = CreateTodoTool.parseDueDate(dueBeforeStr) {
            filtered = filtered.filter { todo in
                guard let due = todo.dueDate else { return false }
                return due < dueBefore
            }
        }

        if let priorityMinStr = input.priorityMin,
           let minPriority = Self.priority(from: priorityMinStr) {
            filtered = filtered.filter { $0.priority.rawValue >= minPriority.rawValue }
        }

        let limit = input.limit ?? 20
        let limited = Array(filtered.prefix(limit))

        let payload = limited.map { todo in
            TodoPayload(
                title: todo.title,
                notes: todo.notes,
                dueDate: todo.dueDate?.formatted(.iso8601),
                priority: Self.priorityName(todo.priority),
                role: todo.role?.slug,
                project: todo.parentProject?.title
            )
        }

        let json = try Self.encodeJSON(payload)
        return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
    }

    private static func decodeInput(_ jsonString: String) throws -> Input {
        let trimmed = jsonString.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return Input(role: nil, dueBefore: nil, priorityMin: nil, limit: nil)
        }
        return (try? JSONDecoder().decode(Input.self, from: data))
            ?? Input(role: nil, dueBefore: nil, priorityMin: nil, limit: nil)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func priority(from string: String) -> TodoPriority? {
        switch string.lowercased() {
        case "low": return .low
        case "normal": return .normal
        case "high": return .high
        case "urgent": return .urgent
        default: return nil
        }
    }

    private static func priorityName(_ p: TodoPriority) -> String {
        switch p {
        case .low: return "low"
        case .normal: return "normal"
        case .high: return "high"
        case .urgent: return "urgent"
        }
    }
}
