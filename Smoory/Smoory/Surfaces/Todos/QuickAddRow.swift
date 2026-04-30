import SwiftData
import SwiftUI

/// Inline quick-add affordance at the top of the Todos surface.
/// Calls `CreateTodoTool.performAction` directly (no confirmation card — explicit user input).
struct QuickAddRow: View {
    let modelContainer: ModelContainer

    @State private var title: String = ""
    @State private var hasDueDate: Bool = false
    @State private var dueDate: Date = Date()
    @State private var showDatePopover: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)

            TextField("Quick add a todo", text: $title)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { add() }

            Button {
                showDatePopover = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: hasDueDate ? "calendar.badge.checkmark" : "calendar")
                        .foregroundStyle(hasDueDate ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    if hasDueDate {
                        Text(dueDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showDatePopover, arrowEdge: .bottom) {
                datePopover
            }

            Button("Add", action: add)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var datePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Has due date", isOn: $hasDueDate)
            if hasDueDate {
                DatePicker("Due", selection: $dueDate, displayedComponents: [.date])
                    .datePickerStyle(.graphical)
                    .frame(maxWidth: 320)
            }
            HStack {
                if hasDueDate {
                    Button("Clear") { hasDueDate = false; showDatePopover = false }
                        .buttonStyle(.borderless)
                }
                Spacer()
                Button("Done") { showDatePopover = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private func add() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try CreateTodoTool.performAction(
                title: trimmed,
                dueDate: hasDueDate ? dueDate : nil,
                source: .userQuickadd,
                modelContainer: modelContainer
            )
            title = ""
            // Keep date setting persistent across rapid entries — feels more like a session preference than per-row.
            isFocused = true
        } catch {
            print("[quickadd] create failed: \(error)")
        }
    }
}
