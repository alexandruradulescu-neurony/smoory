import SwiftUI

/// Flat (no-card) calendar row. Card chrome is reserved for actionable rows
/// (candidates, feed items); calendar events are read-only context.
struct CalendarEventRow: View {
    let item: FeedCalendarLoader.DaySection.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.event.isAllDay ? "All day" : timeRange)
                    .font(.smoory_caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                titleAndSuffix
            }
            if let location = item.event.location {
                Text(location)
                    .font(.smoory_micro)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 118)
            }
        }
        .padding(.vertical, 6)
    }

    private var titleAndSuffix: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(item.event.title)
                .font(.smoory_body)
                .lineLimit(1)
            if let suffix = item.trailingSuffix {
                Text(suffix)
                    .font(.smoory_micro)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var timeRange: String {
        let s = item.event.start.formatted(date: .omitted, time: .shortened)
        let e = item.event.end.formatted(date: .omitted, time: .shortened)
        return "\(s) – \(e)"
    }
}
