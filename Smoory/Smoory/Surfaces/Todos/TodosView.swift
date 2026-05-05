import SwiftData
import SwiftUI

struct TodosView: View {
    @Environment(\.modelContext) private var modelContext

    /// F-4 audit fix: client-side filtered by `TodosViewModel.groupedTodos`. The query is
    /// intentionally unfiltered because "todo-shapedness" mixes signals (due date, priority,
    /// non-empty subtasks, parent list = auto-Todos) that #Predicate can't express cleanly.
    /// Do NOT assume rows here are todo-shaped — always run them through the view-model.
    @Query(sort: \UserListItem.createdAt, order: .reverse) private var allTodos: [UserListItem]
    @State private var viewModel = TodosViewModel()
    @State private var expandedTodoIDs: Set<UUID> = []
    @State private var navigationPath = NavigationPath()

    @State private var pendingUndo: PendingUndo? = nil
    @State private var deferringTodo: UserListItem? = nil

    var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                QuickAddRow(modelContainer: modelContext.container)
                SearchBar(text: $viewModel.searchText, placeholder: "Search todos")
                    .padding(.horizontal)
                    .padding(.top, 8)
                statusFilterPill

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
    private func rowAndSubtasks(for todo: UserListItem) -> some View {
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

    private var statusFilterPill: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterPicker(
                    selected: $viewModel.statusFilter,
                    titleProvider: { $0.title },
                    isAllCase: { $0 == .open }
                )
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    private func sectionHeader(for group: DueDateGroup, count: Int) -> some View {
        HStack(spacing: 6) {
            Circle().fill(group.color).frame(width: 8, height: 8)
            Text(group.title).font(.smoory_heading)
            Text("\(count)").foregroundStyle(.tertiary).font(.smoory_caption)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !viewModel.searchText.isEmpty {
            EmptyState(
                symbol: "checkmark.seal",
                headline: "No todos match \u{201C}\(viewModel.searchText)\u{201D}.",
                detail: nil
            )
            .listRowBackground(Color.clear)
        } else {
            switch viewModel.statusFilter {
            case .open:
                EmptyState(
                    symbol: "checkmark.seal",
                    headline: "No open todos.",
                    detail: "Add one above, or ask Smoory in Chat."
                )
                .listRowBackground(Color.clear)
            case .completed:
                EmptyState(
                    symbol: "checkmark.circle",
                    headline: "No completed todos yet.",
                    detail: nil
                )
                .listRowBackground(Color.clear)
            case .archived:
                EmptyState(
                    symbol: "archivebox",
                    headline: "No archived todos.",
                    detail: nil
                )
                .listRowBackground(Color.clear)
            }
        }
    }

    // MARK: - Mutations

    private func complete(_ todo: UserListItem) {
        do {
            withAnimation(.easeInOut(duration: 0.25)) {
                _ = try? CompleteTodoTool.performAction(todoID: todo.id, modelContainer: modelContext.container)
            }
        }
    }

    private func archive(_ todo: UserListItem) {
        do {
            let result = try DeleteTodoTool.performAction(todoID: todo.id, modelContainer: modelContext.container)
            showUndo(PendingUndo(
                title: result.item.text,
                archivedTodoID: result.item.id,
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

    private func sortedSubtasks(_ parent: UserListItem) -> [UserListItem] {
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
