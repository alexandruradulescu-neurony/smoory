import SwiftData
import SwiftUI

/// Pushed by NavigationStack in TodosView. Edits a single Todo (top-level or subtask).
/// Reads the live Todo via @Query filtered on the id passed in via init, so SwiftData
/// updates from anywhere reflect immediately.
struct TodoDetailView: View {
    let todoID: UUID
    let onArchived: (PendingUndo) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var todos: [Todo]
    @Query(sort: \Role.name) private var allRoles: [Role]

    @State private var editTitle: String = ""
    @State private var editNotes: String = ""
    @State private var hasDueDate: Bool = false
    @State private var dueDate: Date = Date()
    @State private var priority: TodoPriority = .normal
    @State private var roleSlug: String? = nil
    @State private var didLoad: Bool = false

    @State private var newSubtaskTitle: String = ""
    @State private var deferringSubtask: Todo? = nil

    init(todoID: UUID, onArchived: @escaping (PendingUndo) -> Void) {
        self.todoID = todoID
        self.onArchived = onArchived
        let predicate = #Predicate<Todo> { $0.id == todoID }
        _todos = Query(filter: predicate)
    }

    private var todo: Todo? { todos.first }

    var body: some View {
        Group {
            if let todo {
                content(for: todo)
            } else {
                ContentUnavailableView("Todo not found", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(todo?.title ?? "Todo")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Save") { save() }
                    .disabled(!hasUnsavedChanges)
            }
        }
        .sheet(item: $deferringSubtask) { subtask in
            DeferPopover(
                todo: subtask,
                modelContainer: modelContext.container,
                onCommit: { deferringSubtask = nil },
                onCancel: { deferringSubtask = nil }
            )
        }
    }

    @ViewBuilder
    private func content(for todo: Todo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                fieldsSection
                if todo.parentTodo == nil {
                    Divider()
                    subtasksSection(parent: todo)
                }
                Divider()
                deleteButton(for: todo)
            }
            .padding()
        }
        .onAppear { loadIfNeeded(from: todo) }
    }

    // MARK: - Fields

    private var fieldsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeledField("Title") {
                TextField("Title", text: $editTitle)
                    .textFieldStyle(.roundedBorder)
            }

            labeledField("Notes") {
                TextEditor(text: $editNotes)
                    .frame(minHeight: 70, maxHeight: 200)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }

            labeledField("Due date") {
                Toggle("Has due date", isOn: $hasDueDate)
                if hasDueDate {
                    DatePicker("Due", selection: $dueDate, displayedComponents: [.date])
                        .datePickerStyle(.compact)
                }
            }

            labeledField("Priority") {
                Picker("", selection: $priority) {
                    Text("Low").tag(TodoPriority.low)
                    Text("Normal").tag(TodoPriority.normal)
                    Text("High").tag(TodoPriority.high)
                    Text("Urgent").tag(TodoPriority.urgent)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if !allRoles.isEmpty {
                labeledField("Role") {
                    Picker("", selection: $roleSlug) {
                        Text("(none)").tag(Optional<String>.none)
                        ForEach(allRoles, id: \.id) { role in
                            Text(role.name).tag(Optional(role.slug))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }
        }
    }

    @ViewBuilder
    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.smoory_caption).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Subtasks

    @ViewBuilder
    private func subtasksSection(parent: Todo) -> some View {
        let liveSubtasks = parent.subtasks
            .filter { !$0.isArchived }
            .sorted { lhs, rhs in
                if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
                return lhs.createdAt < rhs.createdAt
            }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Subtasks").font(.smoory_heading)
                let progress = parent.subtaskProgress
                if progress.total > 0 {
                    Text("\(progress.completed)/\(progress.total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if liveSubtasks.isEmpty {
                Text("No subtasks yet.")
                    .font(.smoory_caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(liveSubtasks) { sub in
                    subtaskDetailRow(sub: sub)
                }
            }

            HStack(spacing: 8) {
                TextField("Add a subtask", text: $newSubtaskTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addSubtask(parent: parent) }
                Button("Add") { addSubtask(parent: parent) }
                    .buttonStyle(.bordered)
                    .disabled(newSubtaskTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    @ViewBuilder
    private func subtaskDetailRow(sub: Todo) -> some View {
        HStack(spacing: 8) {
            Button {
                completeSubtask(sub)
            } label: {
                Image(systemName: sub.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(sub.isCompleted ? .green : .secondary)
            }
            .buttonStyle(.borderless)

            NavigationLink(value: sub.id) {
                HStack(spacing: 6) {
                    Text(sub.title)
                        .strikethrough(sub.isCompleted)
                        .foregroundStyle(sub.isCompleted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    if let d = sub.dueDate {
                        DueDatePill(dueDate: d, group: DueDateGroup.group(for: sub))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            Menu {
                Button("Defer…") { deferringSubtask = sub }
                Button("Delete", role: .destructive) { archiveSubtask(sub) }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 22)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Delete

    @ViewBuilder
    private func deleteButton(for todo: Todo) -> some View {
        Button(role: .destructive) {
            archiveTodo(todo)
        } label: {
            Label("Delete this todo", systemImage: "trash")
                .foregroundStyle(.red)
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Actions

    private func save() {
        guard let todo else { return }
        let resolvedRole: Role? = {
            if let slug = roleSlug, !slug.isEmpty {
                return allRoles.first(where: { $0.slug == slug })
            }
            return nil
        }()
        do {
            try UpdateTodoTool.saveChanges(
                to: todo,
                title: editTitle,
                notes: editNotes,
                dueDate: hasDueDate ? dueDate : nil,
                priority: priority,
                role: resolvedRole,
                in: modelContext,
                modelContainer: modelContext.container
            )
        } catch {
            print("[detail] save failed: \(error)")
        }
    }

    private func completeSubtask(_ sub: Todo) {
        do {
            try CompleteTodoTool.performAction(todoID: sub.id, modelContainer: modelContext.container)
        } catch {
            print("[detail] complete subtask failed: \(error)")
        }
    }

    private func addSubtask(parent: Todo) {
        let trimmed = newSubtaskTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try CreateSubtaskTool.performAction(
                parentTodoID: parent.id,
                title: trimmed,
                source: .userQuickadd,
                modelContainer: modelContext.container
            )
            newSubtaskTitle = ""
        } catch {
            print("[detail] add subtask failed: \(error)")
        }
    }

    private func archiveSubtask(_ sub: Todo) {
        do {
            let result = try DeleteTodoTool.performAction(todoID: sub.id, modelContainer: modelContext.container)
            onArchived(PendingUndo(
                title: result.todo.title,
                archivedTodoID: result.todo.id,
                archivedSubtaskIDs: result.archivedSubtaskIDs,
                expiresAt: Date().addingTimeInterval(5)
            ))
        } catch {
            print("[detail] archive subtask failed: \(error)")
        }
    }

    private func archiveTodo(_ todo: Todo) {
        do {
            let result = try DeleteTodoTool.performAction(todoID: todo.id, modelContainer: modelContext.container)
            onArchived(PendingUndo(
                title: result.todo.title,
                archivedTodoID: result.todo.id,
                archivedSubtaskIDs: result.archivedSubtaskIDs,
                expiresAt: Date().addingTimeInterval(5)
            ))
            dismiss()
        } catch {
            print("[detail] archive failed: \(error)")
        }
    }

    // MARK: - Loading + dirty tracking

    private func loadIfNeeded(from todo: Todo) {
        guard !didLoad else { return }
        editTitle = todo.title
        editNotes = todo.notes
        hasDueDate = todo.dueDate != nil
        dueDate = todo.dueDate ?? Date()
        priority = todo.priority
        roleSlug = todo.role?.slug
        didLoad = true
    }

    private var hasUnsavedChanges: Bool {
        guard let todo, didLoad else { return false }
        if editTitle != todo.title { return true }
        if editNotes != todo.notes { return true }
        if hasDueDate != (todo.dueDate != nil) { return true }
        if hasDueDate, let cur = todo.dueDate, !Calendar.current.isDate(cur, inSameDayAs: dueDate) { return true }
        if priority != todo.priority { return true }
        if roleSlug != todo.role?.slug { return true }
        return false
    }
}
