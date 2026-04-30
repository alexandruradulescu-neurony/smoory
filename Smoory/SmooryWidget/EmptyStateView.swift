import SwiftUI
import WidgetKit

struct EmptyStateView: View {
    let staleness: BriefStaleness
    let family: WidgetFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: symbol)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            Text(headline)
                .font(.system(.headline, weight: .semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var symbol: String {
        switch staleness {
        case .missing:           return "sun.horizon"
        case .older:             return "clock.arrow.circlepath"
        case .yesterday, .today: return "sun.horizon.fill"
        }
    }

    private var headline: String {
        switch staleness {
        case .missing:   return "Welcome to Smoory."
        case .older:     return "It's been a while."
        case .yesterday: return ""
        case .today:     return ""
        }
    }

    private var detail: String {
        switch staleness {
        case .missing:   return "Enable the morning brief in Settings to see your daily focus here."
        case .older:     return "Open Smoory to refresh your brief."
        case .yesterday: return ""
        case .today:     return ""
        }
    }
}
