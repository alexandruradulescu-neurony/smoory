import SwiftUI

struct TodoSubtaskRow: View {
    let subtask: UserListItem
    let onComplete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Spacer().frame(width: 28)

            Button(action: onComplete) {
                Image(systemName: subtask.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(subtask.isCompleted ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            .help(subtask.isCompleted ? "Completed" : "Mark complete")
            .disabled(subtask.isCompleted)

            NavigationLink(value: subtask.id) {
                HStack(spacing: 6) {
                    Text(subtask.text)
                        .font(.smoory_body)
                        .foregroundStyle(subtask.isCompleted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .strikethrough(subtask.isCompleted)
                    if let dueDate = subtask.dueDate {
                        DueDatePill(dueDate: dueDate, group: DueDateGroup.group(for: subtask))
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}
