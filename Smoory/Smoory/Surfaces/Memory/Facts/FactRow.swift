import SwiftUI

struct FactRow: View {
    let fact: SemanticFact

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                if fact.isPrivate {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.tertiary)
                        .imageScale(.small)
                        .padding(.top, 2)
                }
                Text(fact.body)
                    .font(.smoory_body)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                if !fact.tags.isEmpty {
                    ForEach(fact.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.smoory_micro)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    if fact.tags.count > 3 {
                        Text("+\(fact.tags.count - 3)")
                            .font(.smoory_micro)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Text(Self.relativeAge(fact.createdAt))
                    .font(.smoory_micro)
                    .foregroundStyle(.tertiary)
                Text(Self.confidenceLabel(fact.confidence))
                    .font(.smoory_micro)
                    .foregroundStyle(.secondary)
                if fact.userConfirmed {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .imageScale(.small)
                }
            }
        }
        .padding(.vertical, 6)
        .background(fact.isPrivate ? Color.secondary.opacity(0.05) : Color.clear)
    }

    static func relativeAge(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        let days = Int(interval / 86400)
        if days < 14 { return "\(days)d" }
        if days < 60 { return "\(days / 7)w" }
        return "\(days / 30)mo"
    }

    static func confidenceLabel(_ value: Double) -> String {
        // Three-stop visual: ★★★ ≥85, ★★☆ 50–85, ★☆☆ <50.
        if value >= 0.85 { return "★★★" }
        if value >= 0.5 { return "★★☆" }
        return "★☆☆"
    }
}
