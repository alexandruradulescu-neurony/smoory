import Foundation
import SwiftData
import SwiftUI

enum CreateSubtaskTool: Tool {
    static let name = "create_subtask"

    static let description = """
        Add a subtask under an existing parent todo. Subtasks are full Todos with parentTodo set; \
        they inherit the parent's role unless one is specified. Cannot nest beyond one level — \
        the referenced parent must itself be a top-level todo.
        """

    static let confirmationTier: ConfirmationTier = .tier1Quick

    static let inputSchema = ToolInputSchema(
        properties: [
            "parent_todo_id": ToolInputSchemaProperty(
                type: "string",
                description: "UUID of the parent Todo. Must be a top-level todo."
            ),
            "title": ToolInputSchemaProperty(
                type: "string",
                description: "Subtask title. Required."
            ),
            "due_date": ToolInputSchemaProperty(
                type: "string",
                description: "ISO 8601 date. Optional."
            ),
            "priority": ToolInputSchemaProperty(
                type: "string",
                description: "low | normal | high | urgent. Default normal."
            ),
            "role_slug": ToolInputSchemaProperty(
                type: "string",
                description: "Optional role slug. If omitted, subtask inherits the parent's role."
            ),
        ],
        required: ["parent_todo_id", "title"]
    )

    struct Input: Codable {
        var parent_todo_id: String
        var title: String
        var due_date: String?
        var priority: String?
        var role_slug: String?
    }

    static func execute(parametersJSON: String, context: ToolExecutionContext) async throws -> ToolOutput {
        let input = try TodoToolUtils.decode(Input.self, from: parametersJSON)
        guard let parentUUID = UUID(uuidString: input.parent_todo_id) else {
            return TodoToolUtils.errorOutput(toolUseId: context.toolUseId, message: TodoToolError.todoNotFound.errorDescription ?? "")
        }
        let modelContext = ModelContext(context.services.modelContainer)

        var roleOverride: Role? = nil
        if let slug = input.role_slug, !slug.isEmpty {
            let descriptor = FetchDescriptor<Role>()
            let allRoles = (try? modelContext.fetch(descriptor)) ?? []
            roleOverride = allRoles.first(where: { $0.slug == slug })
        }

        let priority = TodoToolUtils.priority(from: input.priority) ?? .normal
        let dueDate = input.due_date.flatMap(CreateTodoTool.parseDueDate)

        do {
            let subtask = try Self.performAction(
                parentTodoID: parentUUID,
                title: input.title,
                dueDate: dueDate,
                priority: priority,
                roleOverride: roleOverride,
                source: .aiProposal,
                modelContainer: context.services.modelContainer
            )
            let json = #"{"status":"created","id":"\#(subtask.id.uuidString)","title":"\#(TodoToolUtils.jsonEscape(subtask.title))","parent_id":"\#(input.parent_todo_id)"}"#
            return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
        } catch {
            return TodoToolUtils.errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }
    }

    /// Direct subtask creation. Pass `roleOverride: nil` to inherit the parent's role; pass a Role
    /// reference to use that explicitly.
    @discardableResult
    static func performAction(
        parentTodoID: UUID,
        title: String,
        dueDate: Date? = nil,
        priority: TodoPriority = .normal,
        roleOverride: Role? = nil,
        source: TodoSource = .aiProposal,
        modelContainer: ModelContainer
    ) throws -> Todo {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw TodoToolError.missingTitle }

        let context = ModelContext(modelContainer)
        guard let parent = TodoToolUtils.fetchTodo(id: parentTodoID.uuidString, in: context) else {
            throw TodoToolError.todoNotFound
        }
        if parent.parentTodo != nil {
            throw TodoToolError.invalidParent
        }

        let subtask = Todo()
        subtask.title = trimmed
        subtask.parentTodo = parent
        subtask.role = roleOverride ?? parent.role
        subtask.priority = priority
        subtask.dueDate = dueDate
        subtask.source = source
        context.insert(subtask)
        try context.save()
        Task { @MainActor in TodosSnapshotWriter.writeFromStore(modelContainer) }
        return subtask
    }

    static func renderSummary(parametersJSON: String, modelContainer: ModelContainer) -> ProposedActionSummary? {
        guard let input = try? TodoToolUtils.decode(Input.self, from: parametersJSON) else { return nil }
        let context = ModelContext(modelContainer)
        let parentTitle = TodoToolUtils.fetchTodo(id: input.parent_todo_id, in: context)?.title ?? "(unknown parent)"
        var bits: [String] = ["under: \(parentTitle)"]
        if let dueStr = input.due_date, let due = CreateTodoTool.parseDueDate(dueStr) {
            bits.append(TodoToolUtils.relativeDateLabel(due))
        }
        if let prio = input.priority?.lowercased(), prio != "normal", !prio.isEmpty {
            bits.append("\(prio) priority")
        }
        return ProposedActionSummary(
            icon: "text.append",
            title: "Add subtask",
            primary: input.title,
            secondary: bits.joined(separator: " · ")
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
            ?? Input(parent_todo_id: "", title: "")
        return AnyView(CreateSubtaskEditView(initial: initial, onCommit: onCommit, onCancel: onCancel))
    }
}

private struct CreateSubtaskEditView: View {
    @State var input: CreateSubtaskTool.Input
    @State var hasDueDate: Bool
    @State var dueDate: Date
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    init(initial: CreateSubtaskTool.Input, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        _input = State(initialValue: initial)
        let parsed = initial.due_date.flatMap(CreateTodoTool.parseDueDate)
        _hasDueDate = State(initialValue: parsed != nil)
        _dueDate = State(initialValue: parsed ?? Date())
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Subtask title", text: $input.title)
                .textFieldStyle(.roundedBorder)

            Toggle("Has due date", isOn: $hasDueDate)
            if hasDueDate {
                DatePicker("Due", selection: $dueDate, displayedComponents: [.date])
                    .datePickerStyle(.compact)
            }

            HStack {
                Text("Priority")
                Spacer()
                Picker("", selection: priorityBinding) {
                    Text("Low").tag("low")
                    Text("Normal").tag("normal")
                    Text("High").tag("high")
                    Text("Urgent").tag("urgent")
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(input.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var priorityBinding: Binding<String> {
        Binding(get: { input.priority ?? "normal" }, set: { input.priority = $0 })
    }

    private func commit() {
        var out = input
        out.due_date = hasDueDate ? dueDate.formatted(.iso8601) : nil
        let json = (try? JSONEncoder().encode(out))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        onCommit(json)
    }
}
