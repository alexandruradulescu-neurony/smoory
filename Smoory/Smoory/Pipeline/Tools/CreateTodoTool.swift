import Foundation
import SwiftData
import SwiftUI

enum CreateTodoTool: Tool {
    static let name = "create_todo"

    static let description = """
        Create a todo for the user. Use this when the user explicitly asks to add a todo, \
        remind them about something, or capture an action item from the conversation. The \
        user will see a confirmation card with the proposed details before the todo is \
        actually created — they can edit any field before confirming.
        """

    static let confirmationTier: ConfirmationTier = .tier1Quick

    static let inputSchema = ToolInputSchema(
        properties: [
            "title": ToolInputSchemaProperty(
                type: "string",
                description: "Short title for the todo. Required."
            ),
            "notes": ToolInputSchemaProperty(
                type: "string",
                description: "Optional longer notes."
            ),
            "due_date": ToolInputSchemaProperty(
                type: "string",
                description: "ISO 8601 date or date-time. Optional."
            ),
            "priority": ToolInputSchemaProperty(
                type: "string",
                description: "low | normal | high | urgent. Default: normal."
            ),
            "role": ToolInputSchemaProperty(
                type: "string",
                description: "Optional role slug to associate the todo with."
            ),
        ],
        required: ["title"]
    )

    struct Input: Codable {
        var title: String
        var notes: String?
        var due_date: String?
        var priority: String?
        var role: String?
    }

    static func execute(
        parametersJSON: String,
        context: ToolExecutionContext
    ) async throws -> ToolOutput {
        let input = try Self.decodeInput(parametersJSON)
        let modelContext = ModelContext(context.services.modelContainer)

        // Resolve role slug to a Role entity if one matches.
        var role: Role? = nil
        if let slug = input.role, !slug.isEmpty {
            let descriptor = FetchDescriptor<Role>()
            let allRoles = (try? modelContext.fetch(descriptor)) ?? []
            role = allRoles.first(where: { $0.slug == slug })
        }

        let dueDate: Date? = input.due_date.flatMap { try? Date($0, strategy: .iso8601) }

        let priority: TodoPriority = {
            switch input.priority?.lowercased() {
            case "low": return .low
            case "high": return .high
            case "urgent": return .urgent
            default: return .normal
            }
        }()

        let todo = Todo()
        todo.title = input.title
        todo.notes = input.notes ?? ""
        todo.dueDate = dueDate
        todo.priority = priority
        todo.role = role
        todo.source = .aiProposal

        modelContext.insert(todo)
        try modelContext.save()

        let payload: [String: String] = [
            "status": "created",
            "id": todo.id.uuidString,
            "title": todo.title,
        ]
        let json = try Self.encodeJSON(payload)
        return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
    }

    static func renderSummary(parametersJSON: String) -> ProposedActionSummary? {
        guard let input = try? Self.decodeInput(parametersJSON) else { return nil }
        return ProposedActionSummary(
            icon: "checklist",
            title: "Create todo",
            primary: input.title,
            secondary: Self.buildSecondary(from: input)
        )
    }

    @MainActor
    static func makeEditView(
        parametersJSON: String,
        modelContainer: ModelContainer,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) -> AnyView {
        let initial = (try? Self.decodeInput(parametersJSON)) ?? Input(title: "")
        return AnyView(CreateTodoEditView(
            initial: initial,
            onCommit: onCommit,
            onCancel: onCancel
        ))
    }

    // MARK: - Helpers

    private static func decodeInput(_ jsonString: String) throws -> Input {
        guard let data = jsonString.data(using: .utf8), !data.isEmpty else {
            return Input(title: "")
        }
        return try JSONDecoder().decode(Input.self, from: data)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func buildSecondary(from input: Input) -> String? {
        var parts: [String] = []
        if let dueDateStr = input.due_date,
           let due = try? Date(dueDateStr, strategy: .iso8601) {
            parts.append(Self.formatDueDate(due))
        }
        let prio = (input.priority?.lowercased()).flatMap { p -> String? in
            switch p {
            case "low", "normal", "high", "urgent": return "\(p) priority"
            default: return nil
            }
        }
        parts.append(prio ?? "normal priority")
        if let role = input.role, !role.isEmpty {
            parts.append("for \(role)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private static func formatDueDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated).month().day())
    }
}

private struct CreateTodoEditView: View {
    @State var input: CreateTodoTool.Input
    @State var hasDueDate: Bool
    @State var dueDate: Date
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @Query private var roles: [Role]

    init(initial: CreateTodoTool.Input, onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        _input = State(initialValue: initial)
        let parsed = initial.due_date.flatMap { try? Date($0, strategy: .iso8601) }
        _hasDueDate = State(initialValue: parsed != nil)
        _dueDate = State(initialValue: parsed ?? Date())
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $input.title)
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

            if !roles.isEmpty {
                HStack {
                    Text("Role")
                    Spacer()
                    Picker("", selection: roleBinding) {
                        Text("(none)").tag(Optional<String>.none)
                        ForEach(roles, id: \.id) { role in
                            Text(role.name).tag(Optional(role.slug))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
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
    private var roleBinding: Binding<String?> {
        Binding(get: { input.role }, set: { input.role = $0 })
    }

    private func commit() {
        var out = input
        out.due_date = hasDueDate ? dueDate.formatted(.iso8601) : nil
        let json = (try? JSONEncoder().encode(out))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        onCommit(json)
    }
}
