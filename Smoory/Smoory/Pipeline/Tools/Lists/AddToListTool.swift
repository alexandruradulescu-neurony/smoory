import Foundation
import SwiftData

enum AddToListTool: Tool {
    static let name = "add_to_list"

    static let description = """
        Add an item to one of the user's lists. Identify the target by list_id (preferred when \
        known) or list_name (case-insensitive). For checklist-kind lists the new item starts \
        uncompleted. Items are appended to the end of the list by default; pass an explicit \
        position only when the user clearly wants the item placed at a specific spot.
        """

    static let confirmationTier: ConfirmationTier = .silent

    static let inputSchema = ToolInputSchema(
        properties: [
            "list_id": ToolInputSchemaProperty(
                type: "string",
                description: "UUID of the list. Either list_id or list_name is required."
            ),
            "list_name": ToolInputSchemaProperty(
                type: "string",
                description: "Title of the list (case-insensitive). Either list_id or list_name is required."
            ),
            "text": ToolInputSchemaProperty(
                type: "string",
                description: "Item text to add. Required."
            )
        ],
        required: ["text"]
    )

    private struct Input: Decodable {
        let list_id: String?
        let list_name: String?
        let text: String
    }

    private struct OutputPayload: Encodable {
        let id: String
        let text: String
        let list_id: String
        let order: Int
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

        let trimmedText = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            return ListToolUtils.errorOutput(toolUseId: context.toolUseId, message: "text is required")
        }

        let modelContext = ModelContext(context.services.modelContainer)
        do {
            let list = try ListToolUtils.resolveList(
                listID: input.list_id,
                listName: input.list_name,
                in: modelContext
            )
            let item = UserListItem()
            item.text = trimmedText
            item.order = list.nextItemOrder
            let now = Date()
            item.createdAt = now
            item.updatedAt = now
            item.list = list
            modelContext.insert(item)
            list.updatedAt = now
            try modelContext.save()
            await context.services.remindersSyncService?.triggerReconcile()

            let payload = OutputPayload(
                id: item.id.uuidString,
                text: item.text,
                list_id: list.id.uuidString,
                order: item.order,
                status: "added"
            )
            let json = try ListToolUtils.encodeJSON(payload)
            return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
        } catch {
            return ListToolUtils.errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }
    }
}
