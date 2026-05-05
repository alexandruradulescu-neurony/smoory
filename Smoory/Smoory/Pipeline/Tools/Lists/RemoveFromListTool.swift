import Foundation
import SwiftData
import SwiftUI

enum RemoveFromListTool: Tool {
    static let name = "remove_from_list"

    static let description = """
        Permanently remove a single item from its list. The user sees a confirmation card \
        before deletion. Use when the user says "remove that book from my reading list", \
        "drop the eggs item", or similar. Item-level deletion is hard delete — items are \
        cheap to recreate.
        """

    static let confirmationTier: ConfirmationTier = .tier1Quick
    static let supportsEditing: Bool = false

    static let inputSchema = ToolInputSchema(
        properties: [
            "item_id": ToolInputSchemaProperty(
                type: "string",
                description: "UUID of the list item to remove. Required."
            )
        ],
        required: ["item_id"]
    )

    private struct Input: Decodable {
        let item_id: String
    }

    private struct OutputPayload: Encodable {
        let id: String
        let removed: Bool
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
            let parentID = item.list?.id.uuidString ?? ""
            let id = item.id
            item.list?.updatedAt = Date()
            modelContext.delete(item)
            try modelContext.save()

            let payload = OutputPayload(id: id.uuidString, removed: true)
            let json = try ListToolUtils.encodeJSON(payload)
            // parentID currently unused in payload; kept locally so future audit logging
            // can include the surviving list's id without re-fetching.
            _ = parentID
            return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
        } catch {
            return ListToolUtils.errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }
    }

    static func renderSummary(parametersJSON: String, modelContainer: ModelContainer) -> ProposedActionSummary? {
        guard let input = try? ListToolUtils.decode(Input.self, from: parametersJSON) else {
            return ProposedActionSummary(icon: "trash", title: "Remove list item", primary: "(unknown item)", secondary: nil)
        }
        let context = ModelContext(modelContainer)
        do {
            let item = try ListToolUtils.resolveItem(itemID: input.item_id, in: context)
            let listTitle = item.list?.title ?? "(unknown list)"
            return ProposedActionSummary(
                icon: "trash",
                title: "Remove list item",
                primary: item.text,
                secondary: "from \"\(listTitle)\""
            )
        } catch {
            return ProposedActionSummary(icon: "trash", title: "Remove list item", primary: "(unknown item)", secondary: nil)
        }
    }
}
