import Foundation
import SwiftData
import SwiftUI

enum DeleteTodoTool: Tool {
    static let name = "delete_todo"

    static let description = """
        Soft-delete (archive) an existing todo. The todo disappears from open lists but is kept \
        in storage. If the todo has subtasks, they are archived too. Use when the user says they \
        no longer want the todo.
        """

    static let confirmationTier: ConfirmationTier = .tier1Quick
    static let supportsEditing: Bool = false

    static let inputSchema = ToolInputSchema(
        properties: [
            "todo_id": ToolInputSchemaProperty(
                type: "string",
                description: "UUID of the todo to archive."
            ),
        ],
        required: ["todo_id"]
    )

    private struct Input: Decodable {
        let todo_id: String
    }

    static func execute(parametersJSON: String, context: ToolExecutionContext) async throws -> ToolOutput {
        let input = try TodoToolUtils.decode(Input.self, from: parametersJSON)
        guard let uuid = UUID(uuidString: input.todo_id) else {
            return TodoToolUtils.errorOutput(toolUseId: context.toolUseId, message: TodoToolError.todoNotFound.errorDescription ?? "")
        }
        do {
            let result = try Self.performAction(todoID: uuid, modelContainer: context.services.modelContainer)
            let json = #"{"status":"archived","id":"\#(result.todo.id.uuidString)","subtasks_archived":\#(result.archivedSubtaskIDs.count)}"#
            return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
        } catch {
            return TodoToolUtils.errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }
    }

    struct ArchiveResult {
        let todo: Todo
        let archivedSubtaskIDs: [UUID]
    }

    @discardableResult
    static func performAction(todoID: UUID, modelContainer: ModelContainer) throws -> ArchiveResult {
        let context = ModelContext(modelContainer)
        guard let todo = TodoToolUtils.fetchTodo(id: todoID.uuidString, in: context) else {
            throw TodoToolError.todoNotFound
        }
        let now = Date()
        todo.isArchived = true
        todo.archivedAt = now
        todo.updatedAt = now

        var archivedIDs: [UUID] = []
        for sub in todo.subtasks where !sub.isArchived {
            sub.isArchived = true
            sub.archivedAt = now
            sub.updatedAt = now
            archivedIDs.append(sub.id)
        }
        try context.save()
        return ArchiveResult(todo: todo, archivedSubtaskIDs: archivedIDs)
    }

    /// Restores a previously archived todo and a specified set of its subtasks.
    /// Used by the undo banner. Idempotent: missing ids are ignored.
    static func undoArchive(todoID: UUID, archivedSubtaskIDs: [UUID], modelContainer: ModelContainer) throws {
        let context = ModelContext(modelContainer)
        if let todo = TodoToolUtils.fetchTodo(id: todoID.uuidString, in: context) {
            todo.isArchived = false
            todo.archivedAt = nil
            todo.updatedAt = Date()
        }
        for subID in archivedSubtaskIDs {
            if let sub = TodoToolUtils.fetchTodo(id: subID.uuidString, in: context) {
                sub.isArchived = false
                sub.archivedAt = nil
                sub.updatedAt = Date()
            }
        }
        try context.save()
    }

    static func renderSummary(parametersJSON: String, modelContainer: ModelContainer) -> ProposedActionSummary? {
        guard let input = try? TodoToolUtils.decode(Input.self, from: parametersJSON) else { return nil }
        let context = ModelContext(modelContainer)
        guard let todo = TodoToolUtils.fetchTodo(id: input.todo_id, in: context) else {
            return ProposedActionSummary(icon: "trash", title: "Delete todo", primary: "(unknown todo)", secondary: nil)
        }
        let liveSubs = todo.subtasks.filter { !$0.isArchived && !$0.isCompleted }.count
        let secondary: String? = {
            switch liveSubs {
            case 0: return nil
            case 1: return "and 1 subtask"
            default: return "and \(liveSubs) subtasks"
            }
        }()
        return ProposedActionSummary(
            icon: "trash",
            title: "Delete todo",
            primary: todo.title,
            secondary: secondary
        )
    }
}
