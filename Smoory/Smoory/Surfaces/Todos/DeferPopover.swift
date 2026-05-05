import SwiftData
import SwiftUI

/// Compact form for deferring a single todo. Anchored as a popover from row swipe / detail menu.
struct DeferPopover: View {
    let todo: UserListItem
    let modelContainer: ModelContainer
    let onCommit: () -> Void
    let onCancel: () -> Void

    @Environment(\.errorBus) private var errorBus

    @State private var newDueDate: Date = Date().addingTimeInterval(86400)
    @State private var reason: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Defer todo").font(.headline)
            Text(todo.text).font(.callout).foregroundStyle(.secondary).lineLimit(1)

            DatePicker("New due date", selection: $newDueDate, displayedComponents: [.date])
                .datePickerStyle(.compact)

            TextField("Reason (optional)", text: $reason)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Defer") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(minWidth: 280)
        .onAppear {
            if let existing = todo.dueDate, existing > Date() {
                newDueDate = Calendar.current.date(byAdding: .day, value: 1, to: existing) ?? Date().addingTimeInterval(86400)
            }
        }
    }

    private func commit() {
        do {
            try DeferTodoTool.performAction(
                todoID: todo.id,
                newDueDate: newDueDate,
                reason: reason.isEmpty ? nil : reason,
                modelContainer: modelContainer
            )
            onCommit()
        } catch {
            // F-7 audit fix: pre-fix this just print()d and called onCancel(), so the
            // user thought the defer worked. Surface the failure on the bus before
            // dismissing so the user can retry instead of silently losing the action.
            print("[defer] failed: \(error)")
            errorBus?.report("Couldn't defer \"\(todo.text)\": \(error.localizedDescription)")
            onCancel()
        }
    }
}
