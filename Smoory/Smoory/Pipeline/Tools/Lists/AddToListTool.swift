import Foundation
import SwiftData

enum AddToListTool: Tool {
    /// Parses a due-date string. Accepts ISO 8601 with or without time. Returns the
    /// resolved date plus a hint about whether time was present in the input — used to
    /// default `due_has_time` when the LLM didn't supply it explicitly.
    static func parseISODate(_ raw: String) -> (date: Date, inferredHasTime: Bool)? {
        let strict = ISO8601DateFormatter()
        strict.formatOptions = [.withInternetDateTime]
        if let d = strict.date(from: raw) { return (d, true) }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: raw) { return (d, true) }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for (fmt, hasTime) in [
            ("yyyy-MM-dd'T'HH:mm:ss.SSS", true),
            ("yyyy-MM-dd'T'HH:mm:ss", true),
            ("yyyy-MM-dd HH:mm:ss", true),
            ("yyyy-MM-dd HH:mm", true),
            ("yyyy-MM-dd", false)
        ] {
            local.dateFormat = fmt
            if let d = local.date(from: raw) { return (d, hasTime) }
        }
        return nil
    }

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
            ),
            "notes": ToolInputSchemaProperty(
                type: "string",
                description: "Optional long-form note attached to the item."
            ),
            "priority": ToolInputSchemaProperty(
                type: "integer",
                description: "Optional priority. 0 = none (default), 1 = low, 5 = medium, 9 = high. Round-trips with Reminders.app priority."
            ),
            "due_date": ToolInputSchemaProperty(
                type: "string",
                description: "Optional ISO 8601 date or date-time when the item is due."
            ),
            "due_has_time": ToolInputSchemaProperty(
                type: "boolean",
                description: "True if the time component of due_date is meaningful (e.g. 'Friday 3pm'); false for date-only ('due Friday'). Default false when omitted; ignored when due_date is absent."
            ),
            "url": ToolInputSchemaProperty(
                type: "string",
                description: "Optional URL string attached to the item."
            )
        ],
        required: ["text"]
    )

    private struct Input: Decodable {
        let list_id: String?
        let list_name: String?
        let text: String
        let notes: String?
        let priority: Int?
        let due_date: String?
        let due_has_time: Bool?
        let url: String?
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
            // Optional Reminders-parity fields (4.8a). Empty / out-of-range values fall
            // through to the schema defaults so the LLM doesn't need to omit them.
            if let notes = input.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                item.notes = notes
            }
            if let priority = input.priority {
                item.priority = max(0, min(9, priority))
            }
            if let dueRaw = input.due_date?.trimmingCharacters(in: .whitespacesAndNewlines), !dueRaw.isEmpty,
               let parsed = Self.parseISODate(dueRaw) {
                item.dueDate = parsed.date
                item.hasTime = input.due_has_time ?? parsed.inferredHasTime
            }
            if let urlRaw = input.url?.trimmingCharacters(in: .whitespacesAndNewlines), !urlRaw.isEmpty {
                item.urlString = urlRaw
            }
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
