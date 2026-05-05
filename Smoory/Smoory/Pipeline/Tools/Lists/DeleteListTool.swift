import Foundation
import SwiftData
import SwiftUI

enum DeleteListTool: Tool {
    static let name = "delete_list"

    static let description = """
        Soft-delete (archive) an entire list. Items are preserved for restore. The user sees a \
        confirmation card before archival. Identify the list by list_id (preferred) or list_name. \
        Use when the user says "delete my groceries list", "I'm done with the packing list", or \
        similar. To permanently purge an archived list, use the Lists sidebar's archive view.
        """

    static let confirmationTier: ConfirmationTier = .tier1Quick
    static let supportsEditing: Bool = false

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

    private struct OutputPayload: Encodable {
        let id: String
        let title: String
        let archived_at: String
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
            let list = try ListToolUtils.resolveList(
                listID: input.list_id,
                listName: input.list_name,
                in: modelContext
            )
            let now = Date()
            list.isArchived = true
            list.archivedAt = now
            list.updatedAt = now
            try modelContext.save()

            let payload = OutputPayload(
                id: list.id.uuidString,
                title: list.title,
                archived_at: now.formatted(.iso8601),
                status: "archived"
            )
            let json = try ListToolUtils.encodeJSON(payload)
            return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
        } catch {
            return ListToolUtils.errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }
    }

    static func renderSummary(parametersJSON: String, modelContainer: ModelContainer) -> ProposedActionSummary? {
        guard let input = try? ListToolUtils.decode(Input.self, from: parametersJSON) else {
            return ProposedActionSummary(icon: "trash", title: "Archive list", primary: "(unknown list)", secondary: nil)
        }
        let context = ModelContext(modelContainer)
        do {
            let list = try ListToolUtils.resolveList(
                listID: input.list_id,
                listName: input.list_name,
                in: context
            )
            let liveItems = list.items.count
            let secondary: String? = {
                switch liveItems {
                case 0: return "empty list"
                case 1: return "with 1 item"
                default: return "with \(liveItems) items"
                }
            }()
            return ProposedActionSummary(
                icon: "trash",
                title: "Archive list",
                primary: list.title,
                secondary: secondary
            )
        } catch {
            return ProposedActionSummary(icon: "trash", title: "Archive list", primary: "(unknown list)", secondary: nil)
        }
    }
}
