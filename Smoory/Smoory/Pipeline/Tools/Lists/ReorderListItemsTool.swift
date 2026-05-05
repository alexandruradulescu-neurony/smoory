import Foundation
import SwiftData

enum ReorderListItemsTool: Tool {
    static let name = "reorder_list_items"

    static let description = """
        Reorder items in one of the user's lists. Pass `item_id_order` as the FULL ordered \
        list of every item id in the target list — the tool errors if any item is missing or \
        an unknown id is included, so the order is unambiguous. Identify the list via \
        list_id (preferred) or list_name. Typical flow: call get_list_items first to see the \
        current ids, then call this tool with the desired order. Silent — reorder is \
        trivially reversible.
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
            "item_id_order": ToolInputSchemaProperty(
                type: "array",
                description: "Full ordered array of every item UUID in the list, in the desired display order.",
                items: ToolInputSchemaItem(type: "string")
            )
        ],
        required: ["item_id_order"]
    )

    private struct Input: Decodable {
        let list_id: String?
        let list_name: String?
        let item_id_order: [String]
    }

    private struct OutputPayload: Encodable {
        let list_id: String
        let item_count: Int
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

        guard !input.item_id_order.isEmpty else {
            return ListToolUtils.errorOutput(toolUseId: context.toolUseId, message: "item_id_order must not be empty")
        }

        // Pre-validate UUID shape and detect duplicates before touching the DB.
        var requestedIDs: [UUID] = []
        var seen = Set<UUID>()
        for raw in input.item_id_order {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let uuid = UUID(uuidString: trimmed) else {
                return ListToolUtils.errorOutput(
                    toolUseId: context.toolUseId,
                    message: "invalid UUID in item_id_order: '\(trimmed)'"
                )
            }
            if !seen.insert(uuid).inserted {
                return ListToolUtils.errorOutput(
                    toolUseId: context.toolUseId,
                    message: "duplicate item id in item_id_order: '\(trimmed)'"
                )
            }
            requestedIDs.append(uuid)
        }

        let modelContext = ModelContext(context.services.modelContainer)
        do {
            let list = try ListToolUtils.resolveList(
                listID: input.list_id,
                listName: input.list_name,
                in: modelContext
            )
            let existingIDs = Set(list.items.map(\.id))
            let requestedSet = Set(requestedIDs)

            let missing = existingIDs.subtracting(requestedSet)
            if !missing.isEmpty {
                let sample = missing.prefix(3).map { $0.uuidString }.joined(separator: ", ")
                return ListToolUtils.errorOutput(
                    toolUseId: context.toolUseId,
                    message: "item_id_order is missing \(missing.count) item(s) currently in the list (e.g. \(sample))"
                )
            }
            let extra = requestedSet.subtracting(existingIDs)
            if !extra.isEmpty {
                let sample = extra.prefix(3).map { $0.uuidString }.joined(separator: ", ")
                return ListToolUtils.errorOutput(
                    toolUseId: context.toolUseId,
                    message: "item_id_order contains \(extra.count) id(s) not in this list (e.g. \(sample))"
                )
            }

            // Reassign order monotonically. SwiftData persists in-place without re-fetching.
            let now = Date()
            let itemsByID = Dictionary(uniqueKeysWithValues: list.items.map { ($0.id, $0) })
            for (index, id) in requestedIDs.enumerated() {
                if let item = itemsByID[id] {
                    item.order = index
                    item.updatedAt = now
                }
            }
            list.updatedAt = now
            try modelContext.save()

            let payload = OutputPayload(
                list_id: list.id.uuidString,
                item_count: requestedIDs.count,
                status: "reordered"
            )
            let json = try ListToolUtils.encodeJSON(payload)
            return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
        } catch {
            return ListToolUtils.errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }
    }
}
