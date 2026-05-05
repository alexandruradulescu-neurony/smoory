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
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            leadingControl
            VStack(alignment: .leading, spacing: 4) {
                TextField("", text: $item.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .strikethrough(kind == .checklist && item.isCompleted, color: .secondary)
                    .foregroundStyle(kind == .checklist && item.isCompleted ? .secondary : .primary)
                    .onSubmit { item.updatedAt = Date() }
                if showsBadges {
                    badgeRow
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                onEdit()
            } label: {
                Label("Edit details", systemImage: "pencil")
            }
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label("Remove item", systemImage: "trash")
            }
        }
    }

    private var showsBadges: Bool {
        item.priorityBucket != .none
            || item.dueDate != nil
            || (item.notes?.isEmpty == false)
            || item.url != nil
    }

    @ViewBuilder
    private var badgeRow: some View {
        HStack(spacing: 6) {
            // F-5/F-9 audit fix: previous code rendered priority via a local Label +
            // `priorityColor` helper. Both call sites (TodoRow + UserListItemRow) now
            // share `PriorityIndicator(bucket:)` so the icon/tint mapping lives in
            // one place.
            PriorityIndicator(bucket: item.priorityBucket)
            if let due = item.dueDate {
                Label(formattedDue(due, hasTime: item.hasTime), systemImage: "calendar")
                    .font(.caption2)
                    .foregroundStyle(isOverdue(due) ? .red : .secondary)
                    .help("Due \(formattedDue(due, hasTime: item.hasTime))")
            }
            if (item.notes?.isEmpty == false) {
                Image(systemName: "text.alignleft")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Has notes")
            }
            if let url = item.url {
                Link(destination: url) {
                    Image(systemName: "link")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .help(url.absoluteString)
            }
        }
    }

    private func formattedDue(_ date: Date, hasTime: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        if hasTime {
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
        }
        return formatter.string(from: date)
    }

    private func isOverdue(_ date: Date) -> Bool {
        guard kind == .checklist, !item.isCompleted else { return false }
        return date < Date()
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
