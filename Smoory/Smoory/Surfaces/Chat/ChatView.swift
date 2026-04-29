import SwiftUI

struct ChatView: View {
    private let surface: Surface = .chat

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: surface.symbol)
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(surface.title)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(surface.title)
    }
}

#Preview {
    ChatView()
}
