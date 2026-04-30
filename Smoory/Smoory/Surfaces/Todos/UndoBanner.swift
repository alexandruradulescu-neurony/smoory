import SwiftUI

/// Transient banner shown at the bottom of the Todos list after a soft-delete.
/// Held by the parent surface; lifetime managed via a Task delay.
struct PendingUndo: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let archivedTodoID: UUID
    let archivedSubtaskIDs: [UUID]
    let expiresAt: Date
}

struct UndoBanner: View {
    let undo: PendingUndo
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
            Text("Deleted: '\(undo.title)'")
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button("Undo", action: onUndo)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: Color.black.opacity(0.12), radius: 6, y: 2)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
