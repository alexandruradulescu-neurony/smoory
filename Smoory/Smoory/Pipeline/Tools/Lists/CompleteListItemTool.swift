import Foundation
import SwiftData

enum CompleteListItemTool: Tool {
    static let name = "complete_list_item"

    static let description = """
        Mark a checklist item done (or undone, with completed=false). Only valid for items in \
        a checklist-kind list — calling this on an item from a notes-kind list returns an \
        error. Use when the user says "I bought the milk", "mark item N done", or similar. \
        The change is silent (no confirmation card) since toggling state is trivially reversible.
        """

    static let confirmationTier: ConfirmationTier = .silent

    static let inputSchema = ToolInputSchema(
        properties: [
            "item_id": ToolInputSchemaProperty(
                type: "string",
                description: "UUID of the list item. Required."
            ),
            "completed": ToolInputSchemaProperty(
                type: "boolean",
                description: "True to mark done, false to mark undone. Default true."
            )
        ],
        required: ["item_id"]
    )

    private struct Input: Decodable {
        let item_id: String
        let completed: Bool?
    }

    private struct OutputPayload: Encodable {
        let id: String
        let is_completed: Bool
        let completed_at: String?
        let status: String
    }

    static func execute(
        parametersJSON: String,
        context: ToolExecutionContext
    ) async throws -> ToolOutput {
        let input: Input
        do {
            input = try ListToolUtils.decode(Input.self, from: parametersJSON)
        } catch {
            return ListToolUtils.errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }

        let modelContext = ModelContext(context.services.modelContainer)
        do {
            let item = try ListToolUtils.resolveItem(itemID: input.item_id, in: modelContext)
            // Surface notes-kind-list completion attempts as errors so the LLM learns
            // not to call this tool against a notes list rather than silently no-op'ing.
            if item.list?.kind == UserListKind.notes {
                throw ListToolUtils.ListToolError.wrongKindForCompletion
            }
            let now = Date()
            let target = input.completed ?? true
            item.isCompleted = target
            item.completedAt = target ? now : nil
            item.updatedAt = now
            item.list?.updatedAt = now
            try modelContext.save()
            await context.services.remindersSyncService?.triggerReconcile()

            let payload = OutputPayload(
                id: item.id.uuidString,
                is_completed: item.isCompleted,
                completed_at: item.completedAt?.formatted(.iso8601),
                status: target ? "completed" : "uncompleted"
            )
            let json = try ListToolUtils.encodeJSON(payload)
            return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
        } catch {
            return ListToolUtils.errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }
    }
}
