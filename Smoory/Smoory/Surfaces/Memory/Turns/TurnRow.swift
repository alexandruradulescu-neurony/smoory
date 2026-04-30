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
                    .font(.smoory_caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(FactRow.relativeAge(turn.createdAt))
                    .font(.smoory_micro)
                    .foregroundStyle(.tertiary)
            }
            Text(turn.content)
                .font(.smoory_body)
                .lineLimit(3)
        }
        .padding(.vertical, 6)
    }
}
