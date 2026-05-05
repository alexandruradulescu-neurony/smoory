import Foundation
import SwiftData
import SwiftUI

enum DeferTodoTool: Tool {
    static let name = "defer_todo"

    static let description = """
        Push a todo's due date into the future. Optionally captures a reason that gets appended \
        to the todo's notes for later pattern observation. Increments the todo's deferralCount.
        """

    static let confirmationTier: ConfirmationTier = .tier1Quick

    static let inputSchema = ToolInputSchema(
        properties: [
            "todo_id": ToolInputSchemaProperty(
                type: "string",
                description: "UUID of the todo to defer."
            ),
            "new_due_date": ToolInputSchemaProperty(
                type: "string",
                description: "ISO 8601 date or date-time for the new due date. Required."
            ),
            "reason": ToolInputSchemaProperty(
                type: "string",
                description: "Optional reason captured for week-review pattern observation."
            ),
        ],
        required: ["todo_id", "new_due_date"]
    )

    struct Input: Codable {
        var todo_id: String
        var new_due_date: String
        var reason: String?
    }

    static func execute(parametersJSON: String, context: ToolExecutionContext) async throws -> ToolOutput {
        let input = try TodoToolUtils.decode(Input.self, from: parametersJSON)
        guard let uuid = UUID(uuidString: input.todo_id) else {
            return TodoToolUtils.errorOutput(toolUseId: context.toolUseId, message: TodoToolError.todoNotFound.errorDescription ?? "")
        }
        guard let newDate = CreateTodoTool.parseDueDate(input.new_due_date) else {
            return TodoToolUtils.errorOutput(toolUseId: context.toolUseId, message: TodoToolError.dateParseFailed.errorDescription ?? "")
        }
        do {
            let item = try Self.performAction(
                todoID: uuid,
                newDueDate: newDate,
                reason: input.reason,
                modelContainer: context.services.modelContainer
            )
            await context.services.remindersSyncService?.triggerReconcile()
            let json = #"{"status":"deferred","id":"\#(item.id.uuidString)","deferral_count":\#(item.deferralCount)}"#
            return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
        } catch {
            return TodoToolUtils.errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }
    }

    @discardableResult
    static func performAction(
        todoID: UUID,
        newDueDate: Date,
        reason: String? = nil,
        modelContainer: ModelContainer
    ) throws -> UserListItem {
        let context = ModelContext(modelContainer)
        guard let item = TodoToolUtils.fetchItem(id: todoID.uuidString, in: context) else {
            throw TodoToolError.todoNotFound
        }
        if let oldDue = item.dueDate {
            item.deferredFrom = oldDue
        }
        item.dueDate = newDueDate
        item.deferralCount += 1
        let now = Date()
        item.updatedAt = now
        item.list?.updatedAt = now

        if let reason = reason?.trimmingCharacters(in: .whitespaces), !reason.isEmpty {
            let stamp = Date().formatted(.dateTime.year().month(.abbreviated).day())
            let line = "\n[Deferred \(stamp): \(reason)]"
            let prior = item.notes ?? ""
            item.notes = prior + line
        }
        try context.save()
        Task { @MainActor in TodosSnapshotWriter.writeFromStore(modelContainer) }
        return item
    }

    static func renderSummary(parametersJSON: String, modelContainer: ModelContainer) -> ProposedActionSummary? {
        guard let input = try? TodoToolUtils.decode(Input.self, from: parametersJSON) else { return nil }
        let context = ModelContext(modelContainer)
        let title = TodoToolUtils.fetchItem(id: input.todo_id, in: context)?.text ?? "(unknown todo)"
        let oldDate = TodoToolUtils.fetchItem(id: input.todo_id, in: context)?.dueDate
        let newDate = CreateTodoTool.parseDueDate(input.new_due_date)

        var parts: [String] = []
        if let new = newDate {
            parts.append("to \(TodoToolUtils.relativeDateLabel(new))")
        }
        if let old = oldDate {
            parts.append("was \(TodoToolUtils.relativeDateLabel(old))")
        }
        if let reason = input.reason, !reason.isEmpty {
            parts.append("reason: \(reason)")
        }

        return ProposedActionSummary(
            icon: "clock.arrow.circlepath",
            title: "Defer todo",
            primary: title,
            secondary: parts.isEmpty ? nil : parts.joined(separator: " · ")
        )
    }

    @MainActor
    static func makeEditView(
        parametersJSON: String,
        modelContainer: ModelContainer,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) -> AnyView {
        let initial = (try? TodoToolUtils.decode(Input.self, from: parametersJSON))
            ?? Input(todo_id: "", new_due_date: Date().formatted(.iso8601), reason: nil)
        return AnyView(DeferTodoEditView(initial: initial, onCommit: onCommit, onCancel: onCancel))
    }
}

private struct DeferTodoEditView: View {
    @State var input: DeferTodoTool.Input
    @State var newDate: Date
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    init(initial: DeferTodoTool.Input, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        _input = State(initialValue: initial)
        let parsed = CreateTodoTool.parseDueDate(initial.new_due_date) ?? Date()
        _newDate = State(initialValue: parsed)
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DatePicker("New due date", selection: $newDate, displayedComponents: [.date])
                .datePickerStyle(.compact)

            TextField("Reason (optional)", text: Binding(
                get: { input.reason ?? "" },
                set: { input.reason = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button("Save") { commit() }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func commit() {
        var out = input
        out.new_due_date = newDate.formatted(.iso8601)
        let json = (try? JSONEncoder().encode(out))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        onCommit(json)
    }
}
