import SwiftUI

struct EmptyState: View {
    let symbol: String
    let headline: String
    let detail: String?
    let compact: Bool

    init(symbol: String, headline: String, detail: String? = nil, compact: Bool = false) {
        self.symbol = symbol
        self.headline = headline
        self.detail = detail
        self.compact = compact
    }

    var body: some View {
        VStack(spacing: compact ? 8 : 12) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 32 : 48, weight: .light))
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
        .padding(.vertical, compact ? 24 : 60)
        .padding(.horizontal, 24)
    }
}
