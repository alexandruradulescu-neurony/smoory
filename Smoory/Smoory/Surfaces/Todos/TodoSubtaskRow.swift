import SwiftUI

struct TodoSubtaskRow: View {
    let subtask: Todo

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Spacer().frame(width: 28)

            Circle()
                .stroke(Color.secondary.opacity(0.4), lineWidth: 1.5)
                .frame(width: 16, height: 16)

            Text(subtask.title)
                .font(.callout)
                .foregroundStyle(subtask.isCompleted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .strikethrough(subtask.isCompleted)

            if let dueDate = subtask.dueDate {
                DueDatePill(dueDate: dueDate, group: DueDateGroup.group(for: subtask))
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}
