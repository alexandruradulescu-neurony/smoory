import Foundation
import SwiftData

/// Fires after an `OffPeriod` is confirmed via the candidate flow. Surfaces todos with
/// due dates that fall inside the period, and (post-v1, when calendar write lands) the
/// calendar events that conflict. Each conflict becomes a `FeedItem` of kind
/// `.offPeriodConflict` so the user can act from the Feed surface.
///
/// 4.9 scope:
///   - Todo conflicts: yes. Card text invites a defer.
///   - Calendar conflicts: deferred to a calendar-write milestone — without write
///     access surfacing a conflict card without an action would just clutter Feed.
///
/// See DECISIONS.md §4.9 for the full design contract.
@MainActor
struct OffPeriodProposalGenerator {
    let modelContainer: ModelContainer

    /// Looks up the OffPeriod by id, scans for conflicts, and writes one FeedItem
    /// per conflict. No-op if the OffPeriod no longer exists (user reverted the
    /// confirmation, or the row was deleted between save and this call).
    func proposeConflicts(forOffPeriodID offPeriodID: UUID) async {
        let context = ModelContext(modelContainer)
        guard let off = Self.fetchOffPeriod(id: offPeriodID, in: context) else { return }

        // 1. Open todo-shaped UserListItems with dueDate inside the off-period.
        let conflictingItems = Self.findConflictingTodoItems(off: off, in: context)
        for item in conflictingItems {
            let feedItem = Self.buildTodoConflictFeedItem(off: off, item: item)
            context.insert(feedItem)
        }

        // 2. Calendar conflicts — deferred. When calendar write ships, this branch
        //    becomes: read events via CalendarService.eventsBetween(start, end+1d)
        //    and write a FeedItem per event with action "decline" wired up.

        do {
            try context.save()
        } catch {
            print("[off-period] proposeConflicts save failed: \(error)")
        }
    }

    // MARK: - Internals

    private static func fetchOffPeriod(id: UUID, in context: ModelContext) -> OffPeriod? {
        var descriptor = FetchDescriptor<OffPeriod>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Returns open, non-archived, top-level UserListItems that look like tactical
    /// todos and have a due date overlapping the off-period.
    static func findConflictingTodoItems(off: OffPeriod, in context: ModelContext) -> [UserListItem] {
        let cal = Calendar.current
        let startOfStart = cal.startOfDay(for: off.startDate)
        let endOfEnd = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: off.endDate)) ?? off.endDate

        var descriptor = FetchDescriptor<UserListItem>(
            predicate: #Predicate<UserListItem> {
                $0.isCompleted == false && $0.isArchived == false && $0.parentItem == nil
            }
        )
        descriptor.fetchLimit = 500
        let candidates = (try? context.fetch(descriptor)) ?? []
        return candidates.filter { item in
            guard let due = item.dueDate else { return false }
            // "todo-shaped" filter — same as GetOpenTodosTool / TodosSnapshotWriter.
            let isTodoShaped = item.dueDate != nil
                || item.priority > 0
                || item.role != nil
                || item.parentProject != nil
                || item.parentThread != nil
            guard isTodoShaped else { return false }
            return due >= startOfStart && due < endOfEnd
        }
    }

    /// Builds the FeedItem payload for a single todo-conflict card. Uses payloadJSON
    /// as the audit blob so future Feed renderers can resolve back to the OffPeriod
    /// and the todo without renegotiating the schema.
    private static func buildTodoConflictFeedItem(off: OffPeriod, item: UserListItem) -> FeedItem {
        let feed = FeedItem()
        feed.kind = .offPeriodConflict
        feed.priority = 0.6
        feed.confirmationTier = .tier1Quick
        feed.state = .active
        feed.headline = "Defer \"\(item.text)\" past \(off.kind.displayLabel.lowercased())?"
        let dueLabel = ConflictDueDateLabel.format(item.dueDate ?? Date())
        let endLabel = ConflictDueDateLabel.format(off.endDate)
        feed.body = "Due \(dueLabel) — overlaps your time off through \(endLabel)."
        feed.payloadJSON = Self.encodePayload(off: off, item: item)
        let now = Date()
        feed.createdAt = now
        feed.updatedAt = now
        return feed
    }

    private static func encodePayload(off: OffPeriod, item: UserListItem) -> String {
        let payload: [String: String] = [
            "off_period_id": off.id.uuidString,
            "todo_id": item.id.uuidString,
            "todo_text": item.text,
            "due_date_iso": item.dueDate?.formatted(.iso8601) ?? "",
            "off_start_iso": off.startDate.formatted(.iso8601),
            "off_end_iso": off.endDate.formatted(.iso8601)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}

private enum ConflictDueDateLabel {
    static func format(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "today" }
        if cal.isDateInTomorrow(date) { return "tomorrow" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale.current
        return formatter.string(from: date)
    }
}
