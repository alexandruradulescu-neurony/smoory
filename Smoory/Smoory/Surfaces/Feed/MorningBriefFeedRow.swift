import EventKit
import Foundation
import SwiftData
import SwiftUI

/// Renders a morning brief FeedItem. Hybrid view: the LLM-generated bits
/// (headline, reflective note, goal nudge) come from the persisted payloadJSON,
/// but the today's-calendar and secondary-todos sections render LIVE from
/// SwiftData / EventKit on each appearance so the card stays current as the
/// day progresses (instead of reading like a snapshot from 8 a.m.).
///
/// Bug-fix follow-up to the report: pre-fix, the entire brief was baked into
/// payloadJSON at generation time; checking off todos or having calendar
/// events drift didn't update the card. The widget already pulls live, so
/// the brief in Feed felt frozen by comparison.
struct MorningBriefFeedRow: View {
    let item: FeedItem

    @Environment(\.modelContext) private var modelContext

    @Query(sort: \UserListItem.createdAt, order: .reverse)
    private var allItems: [UserListItem]

    @State private var liveCalendar: [LiveCalendarEntry] = []

    private var brief: MorningBrief? {
        guard let json = item.payloadJSON, !json.isEmpty,
              let data = json.data(using: .utf8)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MorningBrief.self, from: data)
    }

    var body: some View {
        if let brief {
            renderedBrief(brief)
                .task { await refreshCalendar() }
        } else {
            decodeFallback
        }
    }

    @ViewBuilder
    private func renderedBrief(_ brief: MorningBrief) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "sun.horizon.fill")
                    .foregroundStyle(.orange)
                Text("Morning brief")
                    .font(.smoory_caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    Task { await refreshCalendar() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Refresh from current state")
            }

            Text(brief.headline)
                .font(.smoory_display)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if !liveCalendar.isEmpty {
                section(title: "Today's calendar") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(liveCalendar) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(event.isAllDay ? "All day" : timeRange(start: event.start, end: event.end))
                                    .font(.smoory_caption.monospacedDigit())
                                    .foregroundStyle(event.isPast ? Color.tertiary : Color.secondary)
                                    .frame(width: 100, alignment: .leading)
                                Text(event.title)
                                    .font(.smoory_body)
                                    .strikethrough(event.isPast, color: .tertiary)
                                    .foregroundStyle(event.isPast ? Color.tertiary : Color.primary)
                                if let loc = event.location, !loc.isEmpty {
                                    Text("· \(loc)")
                                        .font(.smoory_micro)
                                        .foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }

            let liveTodos = computeLiveSecondaryTodos()
            if !liveTodos.isEmpty {
                section(title: "Worth your attention") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(liveTodos) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: entry.icon)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18)
                                Text(entry.text)
                                    .font(.smoory_body)
                                    .strikethrough(entry.isCompleted, color: .secondary)
                                    .foregroundStyle(entry.isCompleted ? Color.tertiary : Color.primary)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }

            if let note = brief.reflectiveNote, !note.isEmpty {
                Text(note)
                    .font(.smoory_caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if let nudge = brief.goalNudge {
                VStack(alignment: .leading, spacing: 4) {
                    Text(nudge.goalTitle)
                        .font(.smoory_micro)
                        .foregroundStyle(.orange)
                        .textCase(.uppercase)
                    Text(nudge.nudgeText)
                        .font(.smoory_body)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            HStack {
                Spacer()
                Text("Generated \(brief.generatedAt.formatted(.dateTime.hour().minute())) · live data")
                    .font(.smoory_micro)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Live data

    /// Top open todo-shaped items, capped to keep the card compact. Matches the
    /// "todo-shaped" filter used elsewhere (TodosViewModel, GetOpenTodosTool).
    private func computeLiveSecondaryTodos() -> [LiveSecondaryEntry] {
        let candidates = allItems.filter { item in
            guard !item.isArchived, item.parentItem == nil else { return false }
            if item.list?.title == TodoToolUtils.defaultTodosListTitle { return true }
            return item.dueDate != nil
                || item.priority > 0
                || item.role != nil
                || item.parentProject != nil
                || item.parentThread != nil
        }
        // Show up to 4: prioritize incomplete with overdue dates, then high priority,
        // then completed-today (so the user sees their progress).
        let now = Date()
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let active = candidates.filter { !$0.isCompleted }
            .sorted { lhs, rhs in
                let lOverdue = (lhs.dueDate ?? .distantFuture) < now
                let rOverdue = (rhs.dueDate ?? .distantFuture) < now
                if lOverdue != rOverdue { return lOverdue }
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return (lhs.dueDate ?? .distantFuture) < (rhs.dueDate ?? .distantFuture)
            }
        let completedToday = candidates.filter {
            $0.isCompleted && ($0.completedAt ?? .distantPast) >= startOfToday
        }
        let combined = (active.prefix(3) + completedToday.prefix(2))
        return combined.map { item in
            LiveSecondaryEntry(
                id: item.id,
                icon: iconFor(item: item),
                text: secondaryText(for: item),
                isCompleted: item.isCompleted
            )
        }
    }

    private func iconFor(item: UserListItem) -> String {
        if item.isCompleted { return "checkmark.circle.fill" }
        if let due = item.dueDate, due < Date() { return "exclamationmark.circle" }
        if item.priority >= 6 { return "flag.fill" }
        return "circle"
    }

    private func secondaryText(for item: UserListItem) -> String {
        var parts: [String] = [item.text]
        if !item.isCompleted, let due = item.dueDate {
            let cal = Calendar.current
            if cal.isDateInToday(due) { parts.append("· today") }
            else if cal.isDateInTomorrow(due) { parts.append("· tomorrow") }
            else if due < Date() { parts.append("· overdue") }
        }
        return parts.joined(separator: " ")
    }

    @MainActor
    private func refreshCalendar() async {
        // Construct a per-render CalendarService — cheap, and avoids needing to
        // thread the singleton through the FeedView hierarchy.
        let service = CalendarService()
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        do {
            let window = try await service.eventsForCurrentWindow()
            let todays = window.days.first(where: { cal.isDate($0.date, inSameDayAs: startOfToday) })
                ?? window.days.first
            let events = todays?.events ?? []
            let now = Date()
            liveCalendar = events.map { e in
                LiveCalendarEntry(
                    id: e.id,
                    title: e.title,
                    start: e.start,
                    end: e.end,
                    location: e.location,
                    isAllDay: e.isAllDay,
                    isPast: e.end < now
                )
            }
        } catch {
            // Silently leave liveCalendar empty on auth-denied or fetch failure;
            // the section just doesn't render. Users see the brief headline + nudge.
            liveCalendar = []
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.smoory_micro)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            content()
        }
    }

    private func timeRange(start: Date, end: Date) -> String {
        let s = start.formatted(date: .omitted, time: .shortened)
        let f = end.formatted(date: .omitted, time: .shortened)
        return "\(s) – \(f)"
    }

    @ViewBuilder
    private var decodeFallback: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Morning brief")
                .font(.smoory_micro)
                .foregroundStyle(.orange)
                .textCase(.uppercase)
            Text(item.headline.isEmpty ? "Couldn't decode brief" : item.headline)
                .font(.smoory_body)
            Text("Open Debug → Open today's brief JSON to inspect the raw payload.")
                .font(.smoory_micro)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct LiveCalendarEntry: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let location: String?
    let isAllDay: Bool
    let isPast: Bool
}

private struct LiveSecondaryEntry: Identifiable {
    let id: UUID
    let icon: String
    let text: String
    let isCompleted: Bool
}

private extension Color {
    static var tertiary: Color { Color.secondary.opacity(0.5) }
}
