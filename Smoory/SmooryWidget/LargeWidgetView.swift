import SwiftUI
import WidgetKit

struct LargeWidgetView: View {
    let entry: BriefEntry

    var body: some View {
        switch entry.briefStaleness {
        case .missing, .older:
            EmptyStateView(staleness: entry.briefStaleness, family: .systemLarge)
        case .today, .yesterday:
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let brief = entry.brief {
            VStack(alignment: .leading, spacing: 10) {
                if entry.briefStaleness == .yesterday {
                    Text("Yesterday's brief — today's is generating")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 2)
                }

                header
                headline(brief)

                if !brief.calendar.isEmpty {
                    sectionDivider
                    section(title: "Today's calendar") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(brief.calendar.prefix(5), id: \.startTime) { event in
                                calendarRow(event)
                            }
                        }
                    }
                }

                if !brief.secondaryItems.isEmpty {
                    sectionDivider
                    section(title: "Also on the radar") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(brief.secondaryItems.prefix(4), id: \.text) { item in
                                secondaryRow(item)
                            }
                        }
                    }
                }

                if let note = brief.reflectiveNote, !note.isEmpty {
                    sectionDivider
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let nudge = brief.goalNudge {
                    sectionDivider
                    goalNudgeBlock(nudge)
                }

                if !entry.upcomingActions.isEmpty {
                    sectionDivider
                    section(title: "Upcoming from Smoory") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(entry.upcomingActions.prefix(2)) { action in
                                upcomingRow(action)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text(Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "sun.horizon.fill")
                .foregroundStyle(.orange)
        }
    }

    private func headline(_ brief: WidgetMorningBrief) -> some View {
        Text(brief.headline)
            .font(.system(.headline, weight: .semibold))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(height: 0.5)
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            content()
        }
    }

    // MARK: - Rows

    private func calendarRow(_ event: WidgetCalendarItem) -> some View {
        HStack(spacing: 6) {
            Text(event.isAllDay
                 ? "All day"
                 : event.startTime.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(event.title)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func secondaryRow(_ item: WidgetSecondaryItem) -> some View {
        HStack(spacing: 6) {
            Image(systemName: item.icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(item.text)
                .font(.caption)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private func upcomingRow(_ action: WidgetScheduledAction) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bell")
                .font(.caption2)
                .foregroundStyle(.orange)
                .frame(width: 14)
            Text(action.content)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(action.scheduledFor.formatted(date: .omitted, time: .shortened))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private func goalNudgeBlock(_ nudge: WidgetGoalNudge) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(nudge.goalTitle.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.orange)
            Text(nudge.nudgeText)
                .font(.caption)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
