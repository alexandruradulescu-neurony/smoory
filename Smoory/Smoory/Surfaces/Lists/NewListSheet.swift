import SwiftData
import SwiftUI

/// Sheet shown from the Lists toolbar's "New list" button. Captures title + kind and
/// inserts a new `UserList` row, then notifies the parent via `onCreated` with the new id.
struct NewListSheet: View {
    let modelContainer: ModelContainer
    let onCreated: (UUID) -> Void
    let onCancel: () -> Void

    @Environment(\.errorBus) private var errorBus

    @State private var title: String = ""
    @State private var kind: UserListKind = .checklist
    @FocusState private var titleFieldFocused: Bool

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New list")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Title").font(.caption).foregroundStyle(.secondary)
                TextField("Reading list", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($titleFieldFocused)
                    .onSubmit { if canSubmit { create() } }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Kind").font(.caption).foregroundStyle(.secondary)
                Picker("Kind", selection: $kind) {
                    Label("Checklist", systemImage: "checkmark.square")
                        .tag(UserListKind.checklist)
                    Label("Notes", systemImage: "text.alignleft")
                        .tag(UserListKind.notes)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(kind == .checklist
                     ? "Items have a checkbox. Use for groceries, packing, weekly to-dos."
                     : "Items are plain bullets. Use for books, gift ideas, restaurants.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { titleFieldFocused = true }
    }

    private func create() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let list = try CreateListTool.performCreate(
                title: trimmed,
                kind: kind,
                modelContainer: modelContainer
            )
            onCreated(list.id)
        } catch {
            print("[lists] create failed: \(error)")
            errorBus?.report("Couldn't create \"\(trimmed)\": \(error.localizedDescription)")
        }
    }
}
