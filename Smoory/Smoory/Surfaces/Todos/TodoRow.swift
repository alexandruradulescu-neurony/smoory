import SwiftUI

struct TodoRow: View {
    let todo: UserListItem
    let isExpanded: Bool
    let onComplete: () -> Void
    let onToggleExpand: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onComplete) {
                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(todo.isCompleted ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.borderless)
            .help(todo.isCompleted ? "Completed" : "Mark complete")
            .disabled(todo.isCompleted || todo.isArchived)

            NavigationLink(value: todo.id) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(todo.text)
                        .font(.smoory_body)
                        .strikethrough(todo.isCompleted || todo.isArchived)
                        .foregroundStyle(
                            (todo.isCompleted || todo.isArchived)
                                ? AnyShapeStyle(.tertiary)
                                : AnyShapeStyle(.primary)
                        )

                    HStack(spacing: 6) {
                        if let dueDate = todo.dueDate {
                            DueDatePill(dueDate: dueDate, group: DueDateGroup.group(for: todo))
                        }
                        if todo.priorityBucket != .none {
                            PriorityIndicator(bucket: todo.priorityBucket)
                        }
                        if let role = todo.role {
                            RoleBadge(name: role.name, colorHex: role.colorHex)
                        }
                        if !todo.subtasks.filter({ !$0.isArchived }).isEmpty {
                            let progress = todo.subtaskProgress
                            SubtaskProgressBadge(completed: progress.completed, total: progress.total)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !todo.subtasks.filter({ !$0.isArchived }).isEmpty {
                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.tertiary)
                        .imageScale(.small)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 6)
    }
}
