import SwiftUI

struct EmptyState: View {
    let symbol: String
    let headline: String
    let detail: String?

    init(symbol: String, headline: String, detail: String? = nil) {
        self.symbol = symbol
        self.headline = headline
        self.detail = detail
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 4) {
                Text(headline)
                    .font(.smoory_heading)
                    .foregroundStyle(.secondary)
                if let detail {
                    Text(detail)
                        .font(.smoory_caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal, 24)
    }
}
