import SwiftUI

struct TodoRow: View {
    let todo: Todo
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Circle()
                .stroke(Color.secondary.opacity(0.4), lineWidth: 1.5)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(todo.title).font(.body)

                HStack(spacing: 6) {
                    if let dueDate = todo.dueDate {
                        DueDatePill(dueDate: dueDate, group: DueDateGroup.group(for: todo))
                    }
                    if todo.priority != .normal {
                        PriorityIndicator(priority: todo.priority)
                    }
                    if let role = todo.role {
                        RoleBadge(name: role.name, colorHex: role.colorHex)
                    }
                    if !todo.subtasks.isEmpty {
                        let progress = todo.subtaskProgress
                        SubtaskProgressBadge(completed: progress.completed, total: progress.total)
                    }
                }
            }

            Spacer()

            if !todo.subtasks.isEmpty {
                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.tertiary)
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
