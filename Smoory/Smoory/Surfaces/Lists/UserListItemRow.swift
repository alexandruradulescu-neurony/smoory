import SwiftUI

/// One item row inside the right pane of `ListsView`. Type-aware: checklist kind shows
/// a tappable checkbox and strikethrough for completed items; notes kind shows a plain
/// bullet. Both kinds expose a context-menu remove option that defers the destructive
/// action to a parent-level alert via `onRemove`.
struct UserListItemRow: View {
    @Bindable var item: UserListItem
    let kind: UserListKind
    let onToggle: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            leadingControl
            TextField("", text: $item.text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .strikethrough(kind == .checklist && item.isCompleted, color: .secondary)
                .foregroundStyle(kind == .checklist && item.isCompleted ? .secondary : .primary)
                .onSubmit { item.updatedAt = Date() }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label("Remove item", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var leadingControl: some View {
        switch kind {
        case .checklist:
            Button(action: onToggle) {
                Image(systemName: item.isCompleted ? "checkmark.square.fill" : "square")
                    .foregroundStyle(item.isCompleted ? Color.accentColor : Color.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isCompleted ? "Mark uncompleted" : "Mark completed")
        case .notes:
            Image(systemName: "circle.fill")
                .imageScale(.small)
                .foregroundStyle(.tertiary)
                .frame(width: 18)
        }
    }
}
