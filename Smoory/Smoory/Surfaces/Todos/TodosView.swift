import SwiftData
import SwiftUI

struct TodosView: View {
    @Query(sort: \Todo.createdAt, order: .reverse) private var allTodos: [Todo]
    @State private var viewModel = TodosViewModel()
    @State private var expandedTodoIDs: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            searchBar

            let groups = viewModel.groupedTodos(from: allTodos)

            List {
                if groups.isEmpty {
                    emptyState
                } else {
                    ForEach(groups, id: \.0) { group, todos in
                        Section {
                            ForEach(todos) { todo in
                                TodoRow(
                                    todo: todo,
                                    isExpanded: expandedTodoIDs.contains(todo.id),
                                    onToggleExpand: { toggleExpand(todo.id) }
                                )

                                if expandedTodoIDs.contains(todo.id) {
                                    ForEach(sortedSubtasks(todo)) { subtask in
                                        TodoSubtaskRow(subtask: subtask)
                                    }
                                }
                            }
                        } header: {
                            sectionHeader(for: group, count: todos.count)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .navigationTitle(Surface.todos.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .padding()
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
                Text("Add a todo by talking to Smoory in Chat.")
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

    private func sortedSubtasks(_ parent: Todo) -> [Todo] {
        parent.subtasks.sorted { lhs, rhs in
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
