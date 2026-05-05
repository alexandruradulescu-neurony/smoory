import EventKit
import Foundation
import SwiftData

/// Bidirectional sync between Smoory's `UserList`/`UserListItem` and Apple Reminders.app.
/// Gated behind an explicit Settings opt-in (`UserDefaults` key `lists.remindersSyncEnabled`)
/// AND `EKEventStore` authorization. Either off → reconcile no-ops.
///
/// Triggers:
///   - `EKEventStoreChanged` notification (debounced 300ms) when observing.
///   - Fire-and-forget `triggerReconcile()` from list tools / UI mutators after every save.
///   - User-initiated `syncNow()` from the Lists toolbar.
///
/// Concurrency model: a single `@MainActor` instance holds state. Reconciles are
/// serialized via the `pendingReconcile` / `isReconciling` flags so triggers during a
/// running reconcile coalesce into one follow-up pass rather than queueing N passes.
@MainActor
final class RemindersSyncService {
    static let enabledDefaultsKey = "lists.remindersSyncEnabled"

    private let modelContainer: ModelContainer
    let store = EKEventStore()

    private var observerToken: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private var pendingReconcile = false
    private var isReconciling = false

    private(set) var lastReport: ReconcileReport?

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    deinit {
        if let token = observerToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Permission + opt-in

    var isOptedIn: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    }

    func setOptedIn(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.enabledDefaultsKey)
    }

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    var isAuthorized: Bool {
        authorizationStatus == .fullAccess
    }

    /// Returns the post-request authorization status. Doesn't throw — callers branch on
    /// the returned status to drive UI.
    func requestPermission() async -> EKAuthorizationStatus {
        do {
            _ = try await store.requestFullAccessToReminders()
        } catch {
            print("[reminders] permission request failed: \(error)")
        }
        return EKEventStore.authorizationStatus(for: .reminder)
    }

    // MARK: - Observation lifecycle

    func startObserving() {
        guard observerToken == nil else { return }
        observerToken = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleDebouncedReconcile()
            }
        }
    }

    func stopObserving() {
        if let token = observerToken {
            NotificationCenter.default.removeObserver(token)
            observerToken = nil
        }
        debounceTask?.cancel()
        debounceTask = nil
    }

    // MARK: - Trigger entry points

    /// Fire-and-forget — used by tools and UI after every Smoory-side mutation.
    /// No-op if sync is opted out or unauthorized.
    func triggerReconcile() {
        guard isOptedIn, isAuthorized else { return }
        Task { @MainActor in
            await self.runReconcileLoop()
        }
    }

    /// User-initiated. Throws if reconcile fails. Returns a report with stats.
    @discardableResult
    func syncNow() async throws -> ReconcileReport {
        guard isOptedIn else { return .empty }
        guard isAuthorized else { return .empty }
        // If a reconcile is already running, wait for it; then run one more pass to
        // catch anything that landed during the wait.
        while isReconciling {
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms poll
        }
        let report = try await performReconcile()
        lastReport = report
        return report
    }

    /// Removes a paired EK reminder when its Smoory item is being deleted. Tools call
    /// this BEFORE removing the SwiftData row so reconcile doesn't re-import the orphan.
    func deleteEKReminder(eventKitIdentifier: String?) async {
        guard isOptedIn, isAuthorized, let eid = eventKitIdentifier else { return }
        guard let item = store.calendarItem(withIdentifier: eid) as? EKReminder else { return }
        do {
            try store.remove(item, commit: true)
        } catch {
            print("[reminders] delete EK reminder failed: \(error)")
        }
    }

    // MARK: - Internal reconcile loop

    private func scheduleDebouncedReconcile() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self.runReconcileLoop()
        }
    }

    private func runReconcileLoop() async {
        guard isOptedIn, isAuthorized else { return }
        if isReconciling {
            pendingReconcile = true
            return
        }
        isReconciling = true
        defer { isReconciling = false }

        repeat {
            pendingReconcile = false
            do {
                let report = try await performReconcile()
                lastReport = report
                if !report.isNoOp {
                    print("[reminders] reconcile: \(report.summary)")
                }
            } catch {
                print("[reminders] reconcile failed: \(error)")
            }
        } while pendingReconcile
    }

    // MARK: - Reconcile algorithm

    private func performReconcile() async throws -> ReconcileReport {
        let started = Date()
        var report = ReconcileReportBuilder()

        let context = ModelContext(modelContainer)

        // 1. Eligible Smoory lists: checklist-kind, non-archived. Filter in Swift to avoid
        //    the SwiftData #Predicate quirk on Int-raw enum attributes (matches the
        //    fetch-and-filter pattern used by GetActiveGoalsTool).
        var listDescriptor = FetchDescriptor<UserList>()
        listDescriptor.fetchLimit = 1000
        let allLists = (try? context.fetch(listDescriptor)) ?? []
        let smooryLists = allLists.filter {
            $0.kind == .checklist && !$0.isArchived
        }
        let allSmooryListTitles = Set(allLists.map(\.title))

        // 2. Reminders calendars from EK.
        let ekCalendars = store.calendars(for: .reminder)

        // 3. Pair lists by eventKitIdentifier.
        var pairs: [(UserList, EKCalendar)] = []
        var smooryUnpaired: [UserList] = []
        var ekUnpaired = ekCalendars

        for list in smooryLists {
            if let eid = list.eventKitIdentifier,
               let idx = ekUnpaired.firstIndex(where: { $0.calendarIdentifier == eid }) {
                pairs.append((list, ekUnpaired[idx]))
                ekUnpaired.remove(at: idx)
            } else {
                smooryUnpaired.append(list)
            }
        }

        // 4. Smoory lists without an EK pair → create EK calendar.
        if let source = store.defaultCalendarForNewReminders()?.source {
            for list in smooryUnpaired {
                let cal = EKCalendar(for: .reminder, eventStore: store)
                cal.title = list.title
                cal.source = source
                do {
                    try store.saveCalendar(cal, commit: true)
                    list.eventKitIdentifier = cal.calendarIdentifier
                    list.updatedAt = Date()
                    pairs.append((list, cal))
                    report.listsPushedToEK += 1
                } catch {
                    report.errors.append("create EK calendar '\(list.title)': \(error.localizedDescription)")
                }
            }
        } else if !smooryUnpaired.isEmpty {
            report.errors.append("no default Reminders source — Smoory-only lists won't push (sign in to iCloud or enable Reminders for an account)")
        }

        // 5. EK calendars without a Smoory pair → import as new UserLists.
        for cal in ekUnpaired {
            let title = allSmooryListTitles.contains(cal.title)
                ? "\(cal.title) (imported)"
                : cal.title
            let list = UserList()
            list.title = title
            list.kind = .checklist
            list.eventKitIdentifier = cal.calendarIdentifier
            let now = Date()
            list.createdAt = now
            list.updatedAt = now
            context.insert(list)
            pairs.append((list, cal))
            report.listsImportedFromEK += 1
        }

        // First commit — list-level rows persist before item reconcile so child items
        // can attach via `list = ...` without dangling references.
        do {
            try context.save()
        } catch {
            report.errors.append("save lists: \(error.localizedDescription)")
        }

        // 6. Per pair: reconcile items.
        for (smooryList, ekCal) in pairs {
            await reconcileItems(
                smooryList: smooryList,
                ekCalendar: ekCal,
                context: context,
                report: &report
            )
        }

        // 7. List title reconcile (push Smoory → EK when titles differ; the user-facing
        //    rename path is via the Smoory tool / UI). EK-side renames flow back via the
        //    EKEventStoreChanged notification, but we don't pull title here to avoid
        //    fighting Smoory-side edits — accepted simplification per DECISIONS.md §4.7.
        for (smooryList, ekCal) in pairs {
            if smooryList.title != ekCal.title, smooryList.eventKitIdentifier != nil {
                ekCal.title = smooryList.title
                do {
                    try store.saveCalendar(ekCal, commit: false)
                    report.listsRenamed += 1
                } catch {
                    report.errors.append("rename calendar '\(smooryList.title)': \(error.localizedDescription)")
                }
            }
        }

        // Commit any pending EK changes batched during item reconcile + list rename.
        do {
            try store.commit()
        } catch {
            report.errors.append("commit EK changes: \(error.localizedDescription)")
        }

        // Final SwiftData save for item-level mutations.
        do {
            try context.save()
        } catch {
            report.errors.append("save items: \(error.localizedDescription)")
        }

        let elapsed = Date().timeIntervalSince(started)
        return report.build(durationSeconds: elapsed)
    }

    private func reconcileItems(
        smooryList: UserList,
        ekCalendar: EKCalendar,
        context: ModelContext,
        report: inout ReconcileReportBuilder
    ) async {
        let predicate = store.predicateForReminders(in: [ekCalendar])
        let ekReminders: [EKReminder] = await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { results in
                cont.resume(returning: results ?? [])
            }
        }

        // Pair items by eventKitIdentifier.
        var smooryItems = smooryList.items
        var ekUnpaired = ekReminders
        var pairs: [(UserListItem, EKReminder)] = []
        var matchedSmoory: Set<UUID> = []

        for item in smooryItems {
            if let eid = item.eventKitIdentifier,
               let idx = ekUnpaired.firstIndex(where: { $0.calendarItemIdentifier == eid }) {
                pairs.append((item, ekUnpaired[idx]))
                ekUnpaired.remove(at: idx)
                matchedSmoory.insert(item.id)
            }
        }

        // Smoory items unpaired:
        //   - With eventKitIdentifier: previously synced, now missing in EK → user
        //     deleted in Reminders.app → delete locally.
        //   - Without eventKitIdentifier: never synced yet → push to EK.
        for item in smooryItems where !matchedSmoory.contains(item.id) {
            if item.eventKitIdentifier != nil {
                context.delete(item)
                report.itemsDeletedSmoorySide += 1
            } else {
                let reminder = EKReminder(eventStore: store)
                reminder.calendar = ekCalendar
                reminder.title = item.text
                if item.isCompleted {
                    reminder.isCompleted = true
                    reminder.completionDate = item.completedAt ?? Date()
                }
                do {
                    try store.save(reminder, commit: false)
                    item.eventKitIdentifier = reminder.calendarItemIdentifier
                    item.updatedAt = Date()
                    report.itemsPushedToEK += 1
                } catch {
                    report.errors.append("push item '\(item.text)': \(error.localizedDescription)")
                }
            }
        }

        // EK items without a Smoory pair → import. Without per-item tombstones we can't
        // distinguish "new in EK" from "Smoory-deleted-it but reconcile hasn't fired yet".
        // Tools call `deleteEKReminder` BEFORE deleting locally, which removes the EK row
        // and avoids the ambiguity. So: any EK orphan here is genuinely new from EK side.
        for reminder in ekUnpaired {
            let item = UserListItem()
            item.text = reminder.title ?? ""
            item.isCompleted = reminder.isCompleted
            item.completedAt = reminder.completionDate
            item.order = smooryList.nextItemOrder
            item.eventKitIdentifier = reminder.calendarItemIdentifier
            let now = Date()
            item.createdAt = now
            item.updatedAt = now
            item.list = smooryList
            context.insert(item)
            // Bump nextItemOrder for subsequent imports in this same calendar.
            smooryList.updatedAt = now
            report.itemsImportedFromEK += 1
        }

        // Paired items: LWW reconcile on text + completion.
        for (smooryItem, reminder) in pairs {
            let ekModified = reminder.lastModifiedDate ?? Date.distantPast
            let smooryWins = smooryItem.updatedAt >= ekModified

            let ekTitle = reminder.title ?? ""
            let needsTextSync = ekTitle != smooryItem.text
            let needsCompletionSync = reminder.isCompleted != smooryItem.isCompleted
                || reminder.completionDate != smooryItem.completedAt

            guard needsTextSync || needsCompletionSync else { continue }

            if smooryWins {
                if needsTextSync { reminder.title = smooryItem.text }
                if needsCompletionSync {
                    reminder.isCompleted = smooryItem.isCompleted
                    reminder.completionDate = smooryItem.completedAt
                }
                do {
                    try store.save(reminder, commit: false)
                    report.itemsUpdated += 1
                } catch {
                    report.errors.append("update item '\(smooryItem.text)': \(error.localizedDescription)")
                }
            } else {
                if needsTextSync { smooryItem.text = ekTitle }
                if needsCompletionSync {
                    smooryItem.isCompleted = reminder.isCompleted
                    smooryItem.completedAt = reminder.completionDate
                }
                smooryItem.updatedAt = Date()
                report.itemsUpdated += 1
            }
        }
    }
}
