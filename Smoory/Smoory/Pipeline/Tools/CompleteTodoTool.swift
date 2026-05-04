import Foundation
import SwiftData
import SwiftUI

enum CompleteTodoTool: Tool {
    static let name = "complete_todo"

    static let description = """
        Mark an existing todo as completed. Use after the user says they finished something \
        or asks you to mark it done. Works on top-level todos and subtasks.
        """

    static let confirmationTier: ConfirmationTier = .tier1Quick
    static let supportsEditing: Bool = false

    static let inputSchema = ToolInputSchema(
        properties: [
            "todo_id": ToolInputSchemaProperty(
                type: "string",
                description: "UUID of the todo to complete. Get from get_open_todos."
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
            let todo = try Self.performAction(todoID: uuid, modelContainer: context.services.modelContainer)
            let json = #"{"status":"completed","id":"\#(todo.id.uuidString)","title":"\#(TodoToolUtils.jsonEscape(todo.title))"}"#
            return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
        } catch {
            return TodoToolUtils.errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }
    }

    @discardableResult
    static func performAction(todoID: UUID, modelContainer: ModelContainer) throws -> Todo {
        let context = ModelContext(modelContainer)
        guard let todo = TodoToolUtils.fetchTodo(id: todoID.uuidString, in: context) else {
            throw TodoToolError.todoNotFound
        }
        todo.isCompleted = true
        todo.completedAt = Date()
        todo.updatedAt = Date()
        try context.save()
        Task { @MainActor in TodosSnapshotWriter.writeFromStore(modelContainer) }
        return todo
    }

    static func renderSummary(parametersJSON: String, modelContainer: ModelContainer) -> ProposedActionSummary? {
        guard let input = try? TodoToolUtils.decode(Input.self, from: parametersJSON) else { return nil }
        let context = ModelContext(modelContainer)
        let title = TodoToolUtils.fetchTodo(id: input.todo_id, in: context)?.title ?? "(unknown todo)"
        return ProposedActionSummary(
            icon: "checkmark.circle",
            title: "Mark complete",
            primary: title,
            secondary: nil
        )
    }
}
