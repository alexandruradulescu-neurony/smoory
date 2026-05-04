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
                nowNextRow(brief: brief)
                todosProgressRow
                Spacer(minLength: 0)
            }
        }
    }

    /// Picks the one most relevant calendar event for the medium widget's
    /// single-row treatment. Falls back to brief.calendar (the morning brief's
    /// static day list) when the live snapshot isn't available — preserves
    /// 3.5 behavior in the absent-snapshot case.
    @ViewBuilder
    private func nowNextRow(brief: WidgetMorningBrief) -> some View {
        let events = entry.calendar?.events ?? []
        let pick = events.nowOrNext(at: entry.date)
            ?? fallbackFromBrief(brief: brief)
        if let event = pick {
            let status = liveStatus(for: event, in: events, now: entry.date)
            HStack(spacing: 6) {
                Image(systemName: symbol(for: status))
                    .font(.caption2)
                    .foregroundStyle(color(for: status))
                    .frame(width: 14)
                Text(timeLabel(for: event))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                Text(event.title)
                    .font(.caption)
                    .lineLimit(1)
                if status == .happening {
                    Text("now")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
            }
        } else if !events.isEmpty || entry.calendar != nil {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text("Day's clear")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Bridges WidgetCalendarItem (brief payload) to WidgetCalendarEvent's
    /// nowOrNext picker so the fallback path can also show an active/next event.
    private func fallbackFromBrief(brief: WidgetMorningBrief) -> WidgetCalendarEvent? {
        let mapped = brief.calendar.map {
            WidgetCalendarEvent(
                title: $0.title,
                startTime: $0.startTime,
                endTime: $0.endTime,
                isAllDay: $0.isAllDay,
                location: $0.location
            )
        }
        return mapped.nowOrNext(at: entry.date)
    }

    /// `pick` returned by nowOrNext might be a recently-ended event or an
    /// upcoming one — we want the matching status, not always .happening.
    private func liveStatus(for event: WidgetCalendarEvent, in events: [WidgetCalendarEvent], now: Date) -> CalendarEventStatus {
        event.status(now: now)
    }

    private func timeLabel(for event: WidgetCalendarEvent) -> String {
        if event.isAllDay { return "All day" }
        return event.startTime.formatted(date: .omitted, time: .shortened)
    }

    private func symbol(for status: CalendarEventStatus) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .happening: "circle.fill"
        case .upcoming:  "circle"
        }
    }

    private func color(for status: CalendarEventStatus) -> Color {
        switch status {
        case .completed: .secondary
        case .happening: .accentColor
        case .upcoming:  .secondary
        }
    }

    @ViewBuilder
    private var todosProgressRow: some View {
        if let todos = entry.todos {
            let done = max(todos.totalCount - todos.openCount, 0)
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                if todos.totalCount == 0 {
                    Text("No todos today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(done) of \(todos.totalCount) done")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
