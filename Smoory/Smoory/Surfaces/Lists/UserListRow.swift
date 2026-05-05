import SwiftUI

/// One row in the Lists sidebar picker. Compact: title, kind icon, item count.
struct UserListRow: View {
    let list: UserList

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: list.kind == .checklist ? "checkmark.square" : "text.alignleft")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(list.title.isEmpty ? "Untitled list" : list.title)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if list.isArchived {
                        Text("Archived")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if list.kind == .notes {
                        Text("Local only")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if list.eventKitIdentifier != nil {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Synced with Reminders.app")
            }
            Text(countLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var countLabel: String {
        switch list.kind {
        case .checklist:
            let total = list.itemCount
            let done = list.completedCount
            return total == 0 ? "0" : "\(done)/\(total)"
        case .notes:
            return "\(list.itemCount)"
        }
    }
}
