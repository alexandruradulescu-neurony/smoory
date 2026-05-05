import Foundation
import SwiftData

enum GetListsTool: Tool {
    static let name = "get_lists"

    static let description = """
        List the user's curated lists (reading list, packing list, groceries, gift ideas, \
        etc.). Returns each list's id, title, kind, and item counts. Use this when the user \
        asks "what lists do I have", "show me my lists", or before adding to a list by name \
        to find the right id. Archived lists are excluded by default.
        """

    static let confirmationTier: ConfirmationTier = .silent

    static let inputSchema = ToolInputSchema(
        properties: [
            "include_archived": ToolInputSchemaProperty(
                type: "boolean",
                description: "If true, include archived (deleted) lists. Default false."
            )
        ],
        required: []
    )

    private struct Input: Decodable {
        let include_archived: Bool?
    }

    private struct ListPayload: Encodable {
        let id: String
        let title: String
        let kind: String
        let item_count: Int
        let completed_count: Int
        let is_archived: Bool
        let archived_at: String?
    }

    static func execute(
        parametersJSON: String,
        context: ToolExecutionContext
    ) async throws -> ToolOutput {
        let input = (try? ListToolUtils.decode(Input.self, from: parametersJSON))
            ?? Input(include_archived: nil)
        let includeArchived = input.include_archived ?? false

        let modelContext = ModelContext(context.services.modelContainer)

        var descriptor = FetchDescriptor<UserList>()
        descriptor.sortBy = [SortDescriptor(\.updatedAt, order: .reverse)]
        descriptor.fetchLimit = 500
        let all = (try? modelContext.fetch(descriptor)) ?? []
        let filtered = includeArchived ? all : all.filter { !$0.isArchived }

        let payload = filtered.map { list in
            ListPayload(
                id: list.id.uuidString,
                title: list.title,
                kind: list.kind.wireValue,
                item_count: list.itemCount,
                completed_count: list.completedCount,
                is_archived: list.isArchived,
                archived_at: list.archivedAt?.formatted(.iso8601)
            )
        }

        do {
            let json = try ListToolUtils.encodeJSON(["lists": payload])
            return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
        } catch {
            return ListToolUtils.errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }
    }
}
