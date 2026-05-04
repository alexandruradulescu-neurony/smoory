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

                todaySection(brief: brief)
                todosSection
                fromSmoorySection(brief: brief)

                Spacer(minLength: 0)
            }
        }
    }

    /// TODAY — live calendar from snapshot. Falls back to brief.calendar when
    /// the live snapshot is missing so we don't regress vs the 3.5 widget on a
    /// fresh app install where the snapshot hasn't been written yet.
    @ViewBuilder
    private func todaySection(brief: WidgetMorningBrief) -> some View {
        let liveEvents = entry.calendar?.events
        let fallback: [WidgetCalendarEvent] = brief.calendar.map {
            WidgetCalendarEvent(
                title: $0.title,
                startTime: $0.startTime,
                endTime: $0.endTime,
                isAllDay: $0.isAllDay,
                location: $0.location
            )
        }
        let events = liveEvents ?? fallback
        if !events.isEmpty {
            sectionDivider
            section(title: "Today") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(events.prefix(5))) { event in
                        liveCalendarRow(event)
                    }
                    if events.count > 5 {
                        Text("+ \(events.count - 5) more events")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    /// TODOS — progress header + open list from snapshot. Hidden when the
    /// snapshot is absent OR when there are no todos at all (totalCount == 0).
    @ViewBuilder
    private var todosSection: some View {
        if let todos = entry.todos, todos.totalCount > 0 {
            sectionDivider
            let done = max(todos.totalCount - todos.openCount, 0)
            section(title: "Todos — \(done) of \(todos.totalCount) done") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(todos.openTodos.prefix(5))) { entry in
                        todoRow(entry)
                    }
                    if todos.openTodos.count > 5 {
                        Text("+ \(todos.openTodos.count - 5) more")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    /// FROM SMOORY — reflective note (from morning brief) + goal nudge +
    /// upcoming reminders. Each subsection hidden when empty.
    @ViewBuilder
    private func fromSmoorySection(brief: WidgetMorningBrief) -> some View {
        let hasNote = !(brief.reflectiveNote ?? "").isEmpty
        let hasNudge = brief.goalNudge != nil
        let hasUpcoming = !entry.upcomingActions.isEmpty
        if hasNote || hasNudge || hasUpcoming {
            sectionDivider
            section(title: "From Smoory") {
                VStack(alignment: .leading, spacing: 6) {
                    if let note = brief.reflectiveNote, !note.isEmpty {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let nudge = brief.goalNudge {
                        goalNudgeBlock(nudge)
                    }
                    if hasUpcoming {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(entry.upcomingActions.prefix(2)) { action in
                                upcomingRow(action)
                            }
                        }
                    }
                }
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

    /// Live calendar row with status visualization (completed / happening /
    /// upcoming) computed against entry.date. The "now" suffix appears only
    /// for the actively-happening event.
    private func liveCalendarRow(_ event: WidgetCalendarEvent) -> some View {
        let status = event.status(now: entry.date)
        return HStack(spacing: 6) {
            Image(systemName: liveSymbol(for: status))
                .font(.caption2)
                .foregroundStyle(liveColor(for: status))
                .frame(width: 14)
            Text(event.isAllDay
                 ? "All day"
                 : event.startTime.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit())
                .foregroundStyle(status == .completed ? .tertiary : .secondary)
                .frame(width: 60, alignment: .leading)
            Text(event.title)
                .font(.caption)
                .foregroundStyle(status == .completed ? .secondary : .primary)
                .lineLimit(1)
            if status == .happening {
                Text("now")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
            Spacer(minLength: 0)
        }
    }

    private func liveSymbol(for status: CalendarEventStatus) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .happening: "circle.fill"
        case .upcoming:  "circle"
        }
    }

    private func liveColor(for status: CalendarEventStatus) -> Color {
        switch status {
        case .completed: .secondary
        case .happening: .accentColor
        case .upcoming:  .secondary
        }
    }

    /// Todo row: priority badge + title + optional due-date suffix
    /// ("today" or "overdue").
    private func todoRow(_ todo: WidgetTodoEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: todoSymbol(for: todo.priority))
                .font(.caption2)
                .foregroundStyle(todoColor(for: todo.priority))
                .frame(width: 14)
            Text(todo.title)
                .font(.caption)
                .lineLimit(1)
            if let suffix = dueSuffix(for: todo.dueDate) {
                Text(suffix.text)
                    .font(.caption2)
                    .foregroundStyle(suffix.color)
            }
            Spacer(minLength: 0)
        }
    }

    private func todoSymbol(for priority: String?) -> String {
        switch priority {
        case "high", "urgent": "star.fill"
        case "low":            "minus"
        default:               "circle.fill"
        }
    }

    private func todoColor(for priority: String?) -> Color {
        switch priority {
        case "high", "urgent": .orange
        case "low":            .gray
        default:               .secondary
        }
    }

    private func dueSuffix(for dueDate: Date?) -> (text: String, color: Color)? {
        guard let due = dueDate else { return nil }
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: entry.date)
        let dueDay = cal.startOfDay(for: due)
        if dueDay < startOfToday { return ("overdue", .red) }
        if cal.isDate(dueDay, inSameDayAs: startOfToday) { return ("today", .secondary) }
        return nil
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
