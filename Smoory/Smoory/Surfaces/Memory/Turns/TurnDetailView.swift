import SwiftUI

struct TurnDetailView: View {
    let turn: MemoryTurn
    let hema: HemaService

    @State private var sessionTurns: [MemoryTurn] = []
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                turnBubble(turn: turn, highlighted: true)

                Divider()

                Text("Session context")
                    .font(.headline)

                if isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .padding()
                } else if sessionTurns.count <= 1 {
                    Text("No other turns in this session.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(sessionTurns) { sibling in
                        if sibling.id != turn.id {
                            turnBubble(turn: sibling, highlighted: false)
                        }
                    }
                }

                if let err = loadError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            .padding()
        }
        .navigationTitle("Turn")
        .navigationSubtitle(turn.createdAt.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))
        .task { await loadSessionContext() }
    }

    private func turnBubble(turn t: MemoryTurn, highlighted: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: t.role == .user ? "person.fill" : "sparkles")
                .foregroundStyle(t.role == .user ? AnyShapeStyle(Color.blue) : AnyShapeStyle(Color.purple))
                .frame(width: 22)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(t.role == .user ? "You" : "Smoory")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(t.createdAt.formatted(.dateTime.hour().minute()))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(t.content)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(highlighted ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(highlighted ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
            )

            Spacer()
        }
    }

    private func loadSessionContext() async {
        guard sessionTurns.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            sessionTurns = try await hema.readTurns(inSession: turn.chatSessionID)
        } catch {
            loadError = error.localizedDescription
        }
    }
}
