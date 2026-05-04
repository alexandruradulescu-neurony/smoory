import Foundation
import WidgetKit

struct BriefTimelineProvider: TimelineProvider {
    typealias Entry = BriefEntry

    func placeholder(in context: Context) -> BriefEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (BriefEntry) -> Void) {
        completion(readEntry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BriefEntry>) -> Void) {
        let now = Date()
        let entry = readEntry(at: now)
        // 15-minute refresh cadence. macOS may delay or skip per system load and
        // widget visibility. The main app calls WidgetCenter.shared.reloadAllTimelines()
        // after relevant mutations to push fresh content faster.
        let next = now.addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func readEntry(at date: Date) -> BriefEntry {
        let brief = BriefReader.read()
        let staleness = computeStaleness(brief: brief, now: date)
        let actions = ScheduledActionsReader.read()
            .filter { $0.kind == "userReminder" }
            .sorted { $0.scheduledFor < $1.scheduledFor }
            .prefix(2)
        let calendar = CalendarSnapshotReader.read()
        let todos = TodosSnapshotReader.read()
        return BriefEntry(
            date: date,
            brief: brief,
            briefStaleness: staleness,
            upcomingActions: Array(actions),
            calendar: calendar,
            todos: todos
        )
    }

    private func computeStaleness(brief: WidgetMorningBrief?, now: Date) -> BriefStaleness {
        guard let brief else { return .missing }
        let cal = Calendar.current
        let briefDay = cal.startOfDay(for: brief.forDate)
        let today = cal.startOfDay(for: now)
        let days = cal.dateComponents([.day], from: briefDay, to: today).day ?? 0
        switch days {
        case ..<0: return .today        // forDate in future — treat as fresh
        case 0:    return .today
        case 1:    return .yesterday
        default:   return .older
        }
    }
}
