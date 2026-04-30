import SwiftUI

struct TurnRow: View {
    let turn: MemoryTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: turn.role == .user ? "person.fill" : "sparkles")
                    .foregroundStyle(turn.role == .user ? AnyShapeStyle(Color.blue) : AnyShapeStyle(Color.purple))
                    .imageScale(.small)
                Text(turn.role == .user ? "You" : "Smoory")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(FactRow.relativeAge(turn.createdAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(turn.content)
                .font(.callout)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
    }
}
