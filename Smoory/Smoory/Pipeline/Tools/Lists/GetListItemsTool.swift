import Foundation
import SwiftData

enum GetListItemsTool: Tool {
    static let name = "get_list_items"

    static let description = """
        Read the items in one of the user's lists. Use this when the user asks "what's on my \
        reading list", "show me my groceries", or whenever you need to know the contents of a \
        specific list. Pass either list_id (preferred when known) or list_name (case-insensitive \
        match). Items are returned in the user's preferred display order.
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
            )
        ],
        required: []
    )

    private struct Input: Decodable {
        let list_id: String?
        let list_name: String?
    }

    private struct ItemPayload: Encodable {
        let id: String
        let text: String
        let is_completed: Bool
        let completed_at: String?
        let order: Int
    }

    private struct ListInfo: Encodable {
        let id: String
        let title: String
        let kind: String
    }

    private struct OutputPayload: Encodable {
        let list: ListInfo
        let items: [ItemPayload]
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
            let list = try ListToolUtils.resolveList(
                listID: input.list_id,
                listName: input.list_name,
                in: modelContext
            )
            let items = list.items
                .sorted { $0.order < $1.order }
                .map { item in
                    ItemPayload(
                        id: item.id.uuidString,
                        text: item.text,
                        is_completed: item.isCompleted,
                        completed_at: item.completedAt?.formatted(.iso8601),
                        order: item.order
                    )
                }
            let payload = OutputPayload(
                list: ListInfo(id: list.id.uuidString, title: list.title, kind: list.kind.wireValue),
                items: items
            )
            let json = try ListToolUtils.encodeJSON(payload)
            return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
        } catch {
            return ListToolUtils.errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }
    }
}
