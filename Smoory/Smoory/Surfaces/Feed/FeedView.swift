import SwiftUI

struct FeedView: View {
    private let surface: Surface = .feed

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
    FeedView()
}
