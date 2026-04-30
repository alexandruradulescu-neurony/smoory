import Foundation
import SwiftData
import SwiftUI

enum UpdateTodoTool: Tool {
    static let name = "update_todo"

    static let description = """
        Modify fields of an existing todo. Only fields you include are changed; others stay as-is. \
        Use after the user asks for an edit ("change the dentist todo to next Tuesday", "rename my \
        Apollo todo to ..."). Works on top-level todos and subtasks.
        """

    static let confirmationTier: ConfirmationTier = .tier1Quick

    static let inputSchema = ToolInputSchema(
        properties: [
            "todo_id": ToolInputSchemaProperty(
                type: "string",
                description: "UUID of the todo to update."
            ),
            "title": ToolInputSchemaProperty(type: "string", description: "New title. Optional."),
            "notes": ToolInputSchemaProperty(type: "string", description: "New notes. Optional."),
            "due_date": ToolInputSchemaProperty(
                type: "string",
                description: "New ISO 8601 date or date-time. Optional. Pass empty string to clear."
            ),
            "priority": ToolInputSchemaProperty(
                type: "string",
                description: "low | normal | high | urgent. Optional."
            ),
            "role_slug": ToolInputSchemaProperty(
                type: "string",
                description: "New role slug. Optional. Pass empty string to clear."
            ),
        ],
        required: ["todo_id"]
    )

    struct Input: Codable {
        var todo_id: String
        var title: String?
        var notes: String?
        var due_date: String?
        var priority: String?
        var role_slug: String?
    }

    static func execute(parametersJSON: String, context: ToolExecutionContext) async throws -> ToolOutput {
        let input = try TodoToolUtils.decode(Input.self, from: parametersJSON)
        let modelContext = ModelContext(context.services.modelContainer)

        guard let todo = TodoToolUtils.fetchTodo(id: input.todo_id, in: modelContext) else {
            return TodoToolUtils.errorOutput(toolUseId: context.toolUseId, message: "Todo not found")
        }

        if let title = input.title { todo.title = title }
        if let notes = input.notes { todo.notes = notes }
        if let dueStr = input.due_date {
            if dueStr.isEmpty {
                todo.dueDate = nil
            } else if let date = CreateTodoTool.parseDueDate(dueStr) {
                todo.dueDate = date
            }
        }
        if let prio = TodoToolUtils.priority(from: input.priority) {
            todo.priority = prio
        }
        if let slug = input.role_slug {
            if slug.isEmpty {
                todo.role = nil
            } else {
                let descriptor = FetchDescriptor<Role>()
                let allRoles = (try? modelContext.fetch(descriptor)) ?? []
                todo.role = allRoles.first(where: { $0.slug == slug }) ?? todo.role
            }
        }
        todo.updatedAt = Date()

        try modelContext.save()

        let json = #"{"status":"updated","id":"\#(todo.id.uuidString)","title":"\#(TodoToolUtils.jsonEscape(todo.title))"}"#
        return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
    }

    static func renderSummary(parametersJSON: String, modelContainer: ModelContainer) -> ProposedActionSummary? {
        guard let input = try? TodoToolUtils.decode(Input.self, from: parametersJSON) else { return nil }
        let context = ModelContext(modelContainer)
        let title = TodoToolUtils.fetchTodo(id: input.todo_id, in: context)?.title ?? "(unknown todo)"

        var changes: [String] = []
        if let t = input.title, !t.isEmpty { changes.append("title") }
        if input.notes != nil { changes.append("notes") }
        if input.due_date != nil { changes.append("due date") }
        if input.priority != nil { changes.append("priority") }
        if input.role_slug != nil { changes.append("role") }

        return ProposedActionSummary(
            icon: "pencil.circle",
            title: "Update todo",
            primary: title,
            secondary: changes.isEmpty ? nil : "changes: \(changes.joined(separator: ", "))"
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
            ?? Input(todo_id: "")
        return AnyView(UpdateTodoEditView(
            initial: initial,
            modelContainer: modelContainer,
            onCommit: onCommit,
            onCancel: onCancel
        ))
    }
}

private struct UpdateTodoEditView: View {
    let initialInput: UpdateTodoTool.Input
    let modelContainer: ModelContainer
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var title: String = ""
    @State private var notes: String = ""
    @State private var hasDueDate: Bool = false
    @State private var dueDate: Date = Date()
    @State private var priority: String = "normal"
    @State private var roleSlug: String? = nil

    @State private var currentTitle: String = ""
    @State private var currentNotes: String = ""
    @State private var currentHasDueDate: Bool = false
    @State private var currentDueDate: Date = Date()
    @State private var currentPriority: String = "normal"
    @State private var currentRoleSlug: String? = nil

    @Query private var roles: [Role]

    init(
        initial: UpdateTodoTool.Input,
        modelContainer: ModelContainer,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialInput = initial
        self.modelContainer = modelContainer
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Title", changed: title != currentTitle) {
                TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            }

            field("Notes", changed: notes != currentNotes) {
                TextField("Notes", text: $notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
            }

            let dueChanged = hasDueDate != currentHasDueDate
                || (hasDueDate && currentHasDueDate && !Calendar.current.isDate(dueDate, inSameDayAs: currentDueDate))
            field("Due date", changed: dueChanged) {
                Toggle("Has due date", isOn: $hasDueDate)
                if hasDueDate {
                    DatePicker("Due", selection: $dueDate, displayedComponents: [.date])
                        .datePickerStyle(.compact)
                }
            }

            field("Priority", changed: priority != currentPriority) {
                HStack {
                    Text("Priority"); Spacer()
                    Picker("", selection: $priority) {
                        Text("Low").tag("low")
                        Text("Normal").tag("normal")
                        Text("High").tag("high")
                        Text("Urgent").tag("urgent")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }

            if !roles.isEmpty {
                field("Role", changed: roleSlug != currentRoleSlug) {
                    HStack {
                        Text("Role"); Spacer()
                        Picker("", selection: $roleSlug) {
                            Text("(none)").tag(Optional<String>.none)
                            ForEach(roles, id: \.id) { role in
                                Text(role.name).tag(Optional(role.slug))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }
            }

            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                Spacer()
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 4)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear { loadInitial() }
    }

    /// Subtle highlight for fields whose form value differs from the stored Todo's value.
    @ViewBuilder
    private func field<Content: View>(_ label: String, changed: Bool, @ViewBuilder content: () -> Content) -> some View {
        let body = VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                if changed {
                    Text("→ new").font(.caption2).foregroundStyle(.orange)
                }
            }
            content()
        }
        .padding(6)
        .background(changed ? Color.orange.opacity(0.10) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))

        body
    }

    private func loadInitial() {
        let context = ModelContext(modelContainer)
        let todo = TodoToolUtils.fetchTodo(id: initialInput.todo_id, in: context)

        let storedTitle = todo?.title ?? ""
        let storedNotes = todo?.notes ?? ""
        let storedDue = todo?.dueDate
        let storedPriority = todo.map { TodoToolUtils.priorityName($0.priority) } ?? "normal"
        let storedRoleSlug = todo?.role?.slug

        currentTitle = storedTitle
        currentNotes = storedNotes
        currentHasDueDate = storedDue != nil
        currentDueDate = storedDue ?? Date()
        currentPriority = storedPriority
        currentRoleSlug = storedRoleSlug

        title = initialInput.title ?? storedTitle
        notes = initialInput.notes ?? storedNotes

        if let dueStr = initialInput.due_date {
            if dueStr.isEmpty {
                hasDueDate = false
                dueDate = Date()
            } else if let parsed = CreateTodoTool.parseDueDate(dueStr) {
                hasDueDate = true
                dueDate = parsed
            } else {
                hasDueDate = currentHasDueDate
                dueDate = currentDueDate
            }
        } else {
            hasDueDate = currentHasDueDate
            dueDate = currentDueDate
        }

        priority = initialInput.priority ?? storedPriority
        roleSlug = initialInput.role_slug ?? storedRoleSlug
    }

    private func commit() {
        var out = UpdateTodoTool.Input(todo_id: initialInput.todo_id)
        if title != currentTitle { out.title = title }
        if notes != currentNotes { out.notes = notes }
        if hasDueDate != currentHasDueDate
            || (hasDueDate && !Calendar.current.isDate(dueDate, inSameDayAs: currentDueDate)) {
            out.due_date = hasDueDate ? dueDate.formatted(.iso8601) : ""
        }
        if priority != currentPriority { out.priority = priority }
        if roleSlug != currentRoleSlug { out.role_slug = roleSlug ?? "" }

        let json = (try? JSONEncoder().encode(out))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        onCommit(json)
    }
}
