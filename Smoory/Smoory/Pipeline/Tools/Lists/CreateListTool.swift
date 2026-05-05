import Foundation
import SwiftData

enum CreateListTool: Tool {
    static let name = "create_list"

    static let description = """
        Create a new user list. Use this when the user wants to start a new collection — \
        "make a packing list for Lisbon", "start a reading list", "create a groceries list". \
        Pass title and kind: "checklist" for items with completion state (packing, groceries, \
        weekly to-dos) or "notes" for plain bullet entries (books, gift ideas, restaurants). \
        Returns the new list's id, which can then be used with add_to_list.
        """

    static let confirmationTier: ConfirmationTier = .silent

    static let inputSchema = ToolInputSchema(
        properties: [
            "title": ToolInputSchemaProperty(
                type: "string",
                description: "Title of the list. Required."
            ),
            "kind": ToolInputSchemaProperty(
                type: "string",
                description: "'checklist' or 'notes'. Default 'checklist'."
            )
        ],
        required: ["title"]
    )

    private struct Input: Decodable {
        let title: String
        let kind: String?
    }

    private struct OutputPayload: Encodable {
        let id: String
        let title: String
        let kind: String
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

        let trimmedTitle = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return ListToolUtils.errorOutput(toolUseId: context.toolUseId, message: "title is required")
        }

        let kindRaw = input.kind?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let kind: UserListKind
        if kindRaw.isEmpty {
            kind = .checklist
        } else if let parsed = UserListKind(wireValue: kindRaw) {
            kind = parsed
        } else {
            return ListToolUtils.errorOutput(
                toolUseId: context.toolUseId,
                message: ListToolUtils.ListToolError.invalidKind(value: kindRaw).errorDescription ?? ""
            )
        }

        do {
            let list = try Self.performCreate(
                title: trimmedTitle,
                kind: kind,
                modelContainer: context.services.modelContainer
            )
            await context.services.remindersSyncService?.triggerReconcile()
            let payload = OutputPayload(
                id: list.id.uuidString,
                title: list.title,
                kind: list.kind.wireValue,
                status: "created"
            )
            let json = try ListToolUtils.encodeJSON(payload)
            return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
        } catch {
            return ListToolUtils.errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }
    }

    @discardableResult
    static func performCreate(
        title: String,
        kind: UserListKind,
        modelContainer: ModelContainer
    ) throws -> UserList {
        let context = ModelContext(modelContainer)
        let list = UserList()
        list.title = title
        list.kind = kind
        let now = Date()
        list.createdAt = now
        list.updatedAt = now
        context.insert(list)
        try context.save()
        return list
    }
}
