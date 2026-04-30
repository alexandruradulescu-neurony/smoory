import SwiftData
import SwiftUI

struct TodosView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \Todo.createdAt, order: .reverse) private var allTodos: [Todo]
    @State private var viewModel = TodosViewModel()
    @State private var expandedTodoIDs: Set<UUID> = []
    @State private var navigationPath = NavigationPath()

    @State private var pendingUndo: PendingUndo? = nil
    @State private var deferringTodo: Todo? = nil

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                QuickAddRow(modelContainer: modelContext.container)
                searchBar

                let groups = viewModel.groupedTodos(from: allTodos)

                List {
                    if groups.isEmpty {
                        emptyState
                    } else {
                        ForEach(groups, id: \.0) { group, todos in
                            Section {
                                ForEach(todos) { todo in
                                    rowAndSubtasks(for: todo)
                                }
                            } header: {
                                sectionHeader(for: group, count: todos.count)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            .overlay(alignment: .bottom) {
                if let undo = pendingUndo {
                    UndoBanner(
                        undo: undo,
                        onUndo: { undoArchive(undo) },
                        onDismiss: { withAnimation { pendingUndo = nil } }
                    )
                }
            }
            .navigationTitle(Surface.todos.title)
            .navigationDestination(for: UUID.self) { id in
                TodoDetailView(
                    todoID: id,
                    onArchived: { showUndo($0) }
                )
            }
            .sheet(item: $deferringTodo) { todo in
                DeferPopover(
                    todo: todo,
                    modelContainer: modelContext.container,
                    onCommit: { deferringTodo = nil },
                    onCancel: { deferringTodo = nil }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowAndSubtasks(for todo: Todo) -> some View {
        TodoRow(
            todo: todo,
            isExpanded: expandedTodoIDs.contains(todo.id),
            onComplete: { complete(todo) },
            onToggleExpand: { toggleExpand(todo.id) }
        )
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                deferringTodo = todo
            } label: {
                Label("Defer", systemImage: "clock.arrow.circlepath")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                archive(todo)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                complete(todo)
            } label: {
                Label("Complete", systemImage: "checkmark")
            }
            .tint(.green)
        }

        if expandedTodoIDs.contains(todo.id) {
            ForEach(sortedSubtasks(todo)) { subtask in
                TodoSubtaskRow(
                    subtask: subtask,
                    onComplete: { complete(subtask) }
                )
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    Button { deferringTodo = subtask } label: {
                        Label("Defer", systemImage: "clock.arrow.circlepath")
                    }
                    .tint(.orange)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        archive(subtask)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search todos", text: $viewModel.searchText)
                .textFieldStyle(.plain)
            if !viewModel.searchText.isEmpty {
                Button {
                    viewModel.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func sectionHeader(for group: DueDateGroup, count: Int) -> some View {
        HStack(spacing: 6) {
            Circle().fill(group.color).frame(width: 8, height: 8)
            Text(group.title).font(.headline)
            Text("\(count)").foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            if viewModel.searchText.isEmpty {
                Text("No open todos").font(.headline).foregroundStyle(.secondary)
                Text("Add a todo above, or talk to Smoory in Chat.")
                    .font(.subheadline).foregroundStyle(.tertiary)
            } else {
                Text("No todos matching '\(viewModel.searchText)'")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .listRowBackground(Color.clear)
    }

    // MARK: - Mutations

    private func complete(_ todo: Todo) {
        do {
            withAnimation(.easeInOut(duration: 0.25)) {
                _ = try? CompleteTodoTool.performAction(todoID: todo.id, modelContainer: modelContext.container)
            }
        }
    }

    private func archive(_ todo: Todo) {
        do {
            let result = try DeleteTodoTool.performAction(todoID: todo.id, modelContainer: modelContext.container)
            showUndo(PendingUndo(
                title: result.todo.title,
                archivedTodoID: result.todo.id,
                archivedSubtaskIDs: result.archivedSubtaskIDs,
                expiresAt: Date().addingTimeInterval(5)
            ))
        } catch {
            print("[surface] archive failed: \(error)")
        }
    }

    private func showUndo(_ undo: PendingUndo) {
        withAnimation { pendingUndo = undo }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if pendingUndo?.id == undo.id {
                withAnimation { pendingUndo = nil }
            }
        }
    }

    private func undoArchive(_ undo: PendingUndo) {
        do {
            try DeleteTodoTool.undoArchive(
                todoID: undo.archivedTodoID,
                archivedSubtaskIDs: undo.archivedSubtaskIDs,
                modelContainer: modelContext.container
            )
        } catch {
            print("[surface] undo failed: \(error)")
        }
        withAnimation { pendingUndo = nil }
    }

    private func sortedSubtasks(_ parent: Todo) -> [Todo] {
        parent.subtasks
            .filter { !$0.isArchived }
            .sorted { lhs, rhs in
                if lhs.isCompleted != rhs.isCompleted { return !lhs.isCompleted }
                return lhs.createdAt < rhs.createdAt
            }
    }

    private func toggleExpand(_ id: UUID) {
        if expandedTodoIDs.contains(id) {
            expandedTodoIDs.remove(id)
        } else {
            expandedTodoIDs.insert(id)
        }
    }
}
