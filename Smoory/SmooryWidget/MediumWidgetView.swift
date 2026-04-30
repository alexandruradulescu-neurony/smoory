import SwiftUI
import WidgetKit

struct MediumWidgetView: View {
    let entry: BriefEntry

    var body: some View {
        switch entry.briefStaleness {
        case .missing, .older:
            EmptyStateView(staleness: entry.briefStaleness, family: .systemMedium)
        case .today, .yesterday:
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let brief = entry.brief {
            VStack(alignment: .leading, spacing: 6) {
                topRow
                if entry.briefStaleness == .yesterday {
                    Text("Yesterday's brief")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(brief.headline)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                ForEach(brief.secondaryItems.prefix(2), id: \.text) { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.icon)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(item.text)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
                ForEach(brief.calendar.prefix(2), id: \.startTime) { event in
                    HStack(spacing: 6) {
                        Text(event.isAllDay
                             ? "All day"
                             : event.startTime.formatted(date: .omitted, time: .shortened))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .leading)
                        Text(event.title)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var topRow: some View {
        HStack {
            Text(Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "sun.horizon.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        }
    }
}
