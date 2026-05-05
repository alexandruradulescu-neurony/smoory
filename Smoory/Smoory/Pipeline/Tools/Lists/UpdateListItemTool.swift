import Foundation
import SwiftData

enum UpdateListItemTool: Tool {
    static let name = "update_list_item"

    static let description = """
        Update one or more fields of an existing list item — text, notes, priority, due \
        date, URL. Pass only the fields you want to change; omitted fields stay as they \
        are. Identify the item by item_id (read it from get_list_items). Silent — edits \
        are reversible by re-issuing the tool with the previous values. To clear a field, \
        pass an empty string for text/notes/url, or pass `priority: 0`, or `due_date: ""`. \
        Toggling completion is a separate tool: use complete_list_item.
        """

    static let confirmationTier: ConfirmationTier = .silent

    static let inputSchema = ToolInputSchema(
        properties: [
            "item_id": ToolInputSchemaProperty(
                type: "string",
                description: "UUID of the list item. Required."
            ),
            "text": ToolInputSchemaProperty(
                type: "string",
                description: "New item text. Empty string clears (becomes blank)."
            ),
            "notes": ToolInputSchemaProperty(
                type: "string",
                description: "New long-form note. Empty string clears."
            ),
            "priority": ToolInputSchemaProperty(
                type: "integer",
                description: "Priority 0-9. 0 = none, 1 = low, 5 = medium, 9 = high. Round-trips with Reminders.app."
            ),
            "due_date": ToolInputSchemaProperty(
                type: "string",
                description: "ISO 8601 date or date-time. Empty string clears the due date."
            ),
            "due_has_time": ToolInputSchemaProperty(
                type: "boolean",
                description: "True if due_date carries a meaningful hour+minute. Ignored when due_date is empty/absent."
            ),
            "url": ToolInputSchemaProperty(
                type: "string",
                description: "New URL string. Empty string clears."
            )
        ],
        required: ["item_id"]
    )

    private struct Input: Decodable {
        let item_id: String
        let text: String?
        let notes: String?
        let priority: Int?
        let due_date: String?
        let due_has_time: Bool?
        let url: String?
    }

    private struct OutputPayload: Encodable {
        let id: String
        let text: String
        let priority: Int
        let due_date: String?
        let url: String?
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
            let now = Date()

            // Apply only fields that were provided. nil = leave alone; empty string = clear
            // (for the text-shaped fields). priority and due_date have their own clear
            // semantics documented in the schema.
            if let text = input.text {
                item.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let notes = input.notes {
                let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
                item.notes = trimmed.isEmpty ? nil : trimmed
            }
            if let priority = input.priority {
                item.priority = max(0, min(9, priority))
            }
            if let dueRaw = input.due_date {
                let trimmed = dueRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    item.dueDate = nil
                    item.hasTime = false
                } else if let parsed = AddToListTool.parseISODate(trimmed) {
                    item.dueDate = parsed.date
                    item.hasTime = input.due_has_time ?? parsed.inferredHasTime
                } else {
                    return ListToolUtils.errorOutput(
                        toolUseId: context.toolUseId,
                        message: "could not parse due_date: '\(trimmed)' — use ISO 8601 (yyyy-MM-dd or yyyy-MM-ddTHH:mm:ss)"
                    )
                }
            } else if let hasTime = input.due_has_time, item.dueDate != nil {
                // Caller flipped time-meaningfulness without changing the date itself.
                item.hasTime = hasTime
            }
            if let urlRaw = input.url {
                let trimmed = urlRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                item.urlString = trimmed.isEmpty ? nil : trimmed
            }

            item.updatedAt = now
            item.list?.updatedAt = now
            try modelContext.save()
            await context.services.remindersSyncService?.triggerReconcile()

            let payload = OutputPayload(
                id: item.id.uuidString,
                text: item.text,
                priority: item.priority,
                due_date: item.dueDate?.formatted(.iso8601),
                url: item.urlString,
                status: "updated"
            )
            let json = try ListToolUtils.encodeJSON(payload)
            return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
        } catch {
            return ListToolUtils.errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }
    }
}
