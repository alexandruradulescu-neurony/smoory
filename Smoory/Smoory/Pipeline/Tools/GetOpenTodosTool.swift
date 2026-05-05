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
        let id: String
        let title: String
        let notes: String
        let dueDate: String?
        let priority: String
        let role: String?
        let project: String?
        let subtasks: [TodoPayload]
    }

    static func execute(
        parametersJSON: String,
        context: ToolExecutionContext
    ) async throws -> ToolOutput {
        let input = try Self.decodeInput(parametersJSON)
        let modelContext = ModelContext(context.services.modelContainer)

        var descriptor = FetchDescriptor<UserListItem>()
        descriptor.fetchLimit = 1000
        let allItems = (try? modelContext.fetch(descriptor)) ?? []

        // Top-level only: subtasks ride along nested under their parent payloads, never flat.
        // 4.8c — narrow to "todo-shaped" items: anything in the auto-Todos list, OR with an
        // explicit todo signal (due date, priority, role/project/thread). Excludes plain
        // shopping/reading list rows that weren't created with todo intent.
        var filtered = allItems.filter { item in
            guard !item.isCompleted, !item.isArchived, item.parentItem == nil else { return false }
            if item.list?.title == TodoToolUtils.defaultTodosListTitle { return true }
            return item.dueDate != nil
                || item.priority > 0
                || item.role != nil
                || item.parentProject != nil
                || item.parentThread != nil
        }

        if let roleSlug = input.role {
            filtered = filtered.filter { $0.role?.slug == roleSlug }
        }

        if let dueBeforeStr = input.dueBefore,
           let dueBefore = CreateTodoTool.parseDueDate(dueBeforeStr) {
            filtered = filtered.filter { item in
                guard let due = item.dueDate else { return false }
                return due < dueBefore
            }
        }

        if let priorityMinStr = input.priorityMin,
           let minPriority = TodoToolUtils.priority(from: priorityMinStr) {
            filtered = filtered.filter { $0.priority >= minPriority }
        }

        let limit = input.limit ?? 20
        let limited = Array(filtered.prefix(limit))

        let payload = limited.map { Self.makePayload(item: $0, includeSubtasks: true) }

        let json = try Self.encodeJSON(payload)
        return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
    }

    /// Recursive payload builder. `includeSubtasks` is true for top-level rows so children ride along.
    /// For subtasks themselves we never recurse further (one-level rule, enforced at insertion time).
    private static func makePayload(item: UserListItem, includeSubtasks: Bool) -> TodoPayload {
        let kids = includeSubtasks
            ? item.subtasks
                .filter { !$0.isArchived }
                .map { Self.makePayload(item: $0, includeSubtasks: false) }
            : []
        return TodoPayload(
            id: item.id.uuidString,
            title: item.text,
            notes: item.notes ?? "",
            dueDate: item.dueDate?.formatted(.iso8601),
            priority: TodoToolUtils.priorityName(item.priority),
            role: item.role?.slug,
            project: item.parentProject?.title,
            subtasks: kids
        )
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

}
