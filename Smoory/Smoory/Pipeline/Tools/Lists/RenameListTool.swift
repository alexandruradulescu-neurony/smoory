import Foundation
import SwiftData

enum RenameListTool: Tool {
    static let name = "rename_list"

    static let description = """
        Change the title of an existing user list. Identify the list by list_id (preferred) \
        or list_name (case-insensitive). Use when the user says "rename my groceries list to \
        weekly shop", "call this packing list 'Lisbon trip' instead", or similar. Silent — \
        rename is trivially reversible by calling this tool again.
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
                description: "Current title of the list (case-insensitive). Either list_id or list_name is required."
            ),
            "new_title": ToolInputSchemaProperty(
                type: "string",
                description: "New title for the list. Required."
            )
        ],
        required: ["new_title"]
    )

    private struct Input: Decodable {
        let list_id: String?
        let list_name: String?
        let new_title: String
    }

    private struct OutputPayload: Encodable {
        let id: String
        let title: String
        let previous_title: String
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

        let trimmedTitle = input.new_title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return ListToolUtils.errorOutput(toolUseId: context.toolUseId, message: "new_title is required")
        }

        let modelContext = ModelContext(context.services.modelContainer)
        do {
            let list = try ListToolUtils.resolveList(
                listID: input.list_id,
                listName: input.list_name,
                in: modelContext
            )
            let previousTitle = list.title
            let now = Date()
            list.title = trimmedTitle
            list.updatedAt = now
            try modelContext.save()

            let payload = OutputPayload(
                id: list.id.uuidString,
                title: list.title,
                previous_title: previousTitle,
                status: "renamed"
            )
            let json = try ListToolUtils.encodeJSON(payload)
            return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
        } catch {
            return ListToolUtils.errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }
    }
}
