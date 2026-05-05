import SwiftData
import SwiftUI

struct ListsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.remindersSyncService) private var remindersSyncService

    @Query(sort: \UserList.updatedAt, order: .reverse)
    private var allLists: [UserList]

    @State private var selectedListID: UUID?
    @State private var showingNewListSheet = false
    @State private var showingArchived = false
    @State private var isSyncingReminders = false

    private var visibleLists: [UserList] {
        showingArchived ? allLists : allLists.filter { !$0.isArchived }
    }

    private var selectedList: UserList? {
        guard let id = selectedListID else { return nil }
        return allLists.first(where: { $0.id == id })
    }

    var body: some View {
        NavigationStack {
            HSplitView {
                listPickerColumn
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                itemColumn
                    .frame(minWidth: 360)
            }
            .navigationTitle(Surface.lists.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNewListSheet = true
                    } label: {
                        Label("New list", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: [.command])
                }
                if isRemindersSyncActive {
                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            Task { await runSyncNow() }
                        } label: {
                            if isSyncingReminders {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .disabled(isSyncingReminders)
                        .help("Sync with Reminders.app")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Toggle(isOn: $showingArchived) {
                        Label("Show archived", systemImage: "archivebox")
                    }
                    .toggleStyle(.button)
                }
            }
            .sheet(isPresented: $showingNewListSheet) {
                NewListSheet(
                    modelContainer: modelContext.container,
                    onCreated: { newID in
                        selectedListID = newID
                        showingNewListSheet = false
                    },
                    onCancel: { showingNewListSheet = false }
                )
            }
        }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: visibleLists.map(\.id)) { _, _ in selectFirstIfNeeded() }
    }

    @ViewBuilder
    private var listPickerColumn: some View {
        if visibleLists.isEmpty {
            emptyListsState
        } else {
            List(visibleLists, id: \.id, selection: $selectedListID) { list in
                UserListRow(list: list)
                    .tag(list.id)
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var emptyListsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "list.bullet.rectangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(showingArchived ? "No archived lists." : "No lists yet.")
                .foregroundStyle(.secondary)
            if !showingArchived {
                Button("Create your first list") {
                    showingNewListSheet = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private var itemColumn: some View {
        if let list = selectedList {
            UserListDetail(
                list: list,
                modelContainer: modelContext.container,
                remindersSyncService: remindersSyncService
            )
            .id(list.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sidebar.left")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Select a list")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var isRemindersSyncActive: Bool {
        guard let svc = remindersSyncService else { return false }
        return svc.isOptedIn && svc.isAuthorized
    }

    @MainActor
    private func runSyncNow() async {
        guard let svc = remindersSyncService else { return }
        isSyncingReminders = true
        defer { isSyncingReminders = false }
        do {
            let report = try await svc.syncNow()
            print("[reminders] sync now: \(report.summary)")
            if !report.errors.isEmpty {
                for err in report.errors { print("[reminders] error: \(err)") }
            }
        } catch {
            print("[reminders] sync now failed: \(error)")
        }
    }

    private func selectFirstIfNeeded() {
        if let id = selectedListID, visibleLists.contains(where: { $0.id == id }) {
            return
        }
        selectedListID = visibleLists.first?.id
    }
}

/// Right-pane view for a single selected list — header, item rows with type-aware
/// affordances, inline add field. Pulled into its own struct so .id(list.id) on the
/// parent forces a clean reset on selection change.
struct UserListDetail: View {
    @Bindable var list: UserList
    let modelContainer: ModelContainer
    let remindersSyncService: RemindersSyncService?

    /// Live SwiftData context inherited from the surrounding NavigationStack. All UI
    /// mutations (toggle, remove, archive, reorder, add) flow through this single
    /// context so the @Bindable rows reflect the change immediately. Bug fixed in
    /// the 4.8d follow-up: prior code created a fresh ModelContext per mutation,
    /// which saved to the persistent store but left the in-memory @Bindable rows
    /// stale — checkboxes wouldn't visually toggle.
    @Environment(\.modelContext) private var modelContext

    @State private var newItemText: String = ""
    @State private var pendingItemRemoval: UserListItem?
    @State private var pendingArchive = false
    @State private var editingItem: UserListItem?

    private var sortedItems: [UserListItem] {
        list.items.sorted { $0.order < $1.order }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if list.items.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(sortedItems, id: \.id) { item in
                        UserListItemRow(
                            item: item,
                            kind: list.kind,
                            onToggle: { toggleItem(item) },
                            onRemove: { pendingItemRemoval = item },
                            onEdit: { editingItem = item }
                        )
                    }
                    .onMove(perform: moveItems)
                }
                .listStyle(.inset)
            }
            Divider()
            addItemRow
        }
        .alert("Remove item?", isPresented: itemRemovalAlertBinding, presenting: pendingItemRemoval) { item in
            Button("Remove", role: .destructive) { removeItem(item) }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("\"\(item.text)\" — this can't be undone.")
        }
        .alert("Archive list?", isPresented: $pendingArchive) {
            Button("Archive", role: .destructive) { archiveList() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\"\(list.title)\" and its \(list.itemCount) item(s) will be hidden. You can restore from the archived view.")
        }
        .sheet(item: $editingItem) { item in
            UserListItemDetailSheet(
                item: item,
                modelContainer: modelContainer,
                remindersSyncService: remindersSyncService,
                onClose: { editingItem = nil }
            )
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: list.kind == .checklist ? "checkmark.square" : "text.alignleft")
                        .foregroundStyle(.secondary)
                    Text(list.title.isEmpty ? "Untitled list" : list.title)
                        .font(.title2.weight(.semibold))
                }
                Text(headerSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if list.isArchived {
                Button("Restore") { restoreList() }
            } else {
                Menu {
                    if list.kind == .checklist {
                        Picker("Auto-reset", selection: cadenceBinding) {
                            ForEach(UserListResetCadence.allCases, id: \.self) { cadence in
                                Text(cadence.displayLabel).tag(cadence)
                            }
                        }
                    }
                    Button(role: .destructive) {
                        pendingArchive = true
                    } label: {
                        Label("Archive list", systemImage: "archivebox")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }
        }
        .padding()
    }

    private var headerSubtitle: String {
        let baseLine: String
        switch list.kind {
        case .checklist:
            let total = list.itemCount
            let done = list.completedCount
            baseLine = total == 0 ? "Checklist — no items yet" : "Checklist — \(done) of \(total) done"
        case .notes:
            let total = list.itemCount
            baseLine = total == 0 ? "Notes — no items yet" : "Notes — \(total) item(s)"
        }
        guard list.resetCadence != .none else { return baseLine }
        return "\(baseLine) · auto-resets \(list.resetCadence.displayLabel.lowercased())"
    }

    /// Two-way binding for the auto-reset cadence picker. Writes mutate the @Bindable
    /// list directly so the menu's checkmark updates immediately, and bumps
    /// `lastResetAt` so the next sweep doesn't fire immediately on a brand-new cadence.
    private var cadenceBinding: Binding<UserListResetCadence> {
        Binding(
            get: { list.resetCadence },
            set: { newValue in
                let now = Date()
                list.resetCadence = newValue
                if newValue != .none {
                    list.lastResetAt = now
                }
                list.updatedAt = now
                try? modelContext.save()
            }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Add an item below to get started.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var addItemRow: some View {
        HStack {
            Image(systemName: "plus")
                .foregroundStyle(.secondary)
            TextField("Add item", text: $newItemText)
                .textFieldStyle(.plain)
                .onSubmit { commitNewItem() }
                .disabled(list.isArchived)
            if !newItemText.isEmpty {
                Button("Add") { commitNewItem() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var itemRemovalAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingItemRemoval != nil },
            set: { if !$0 { pendingItemRemoval = nil } }
        )
    }

    // MARK: - Mutations

    private func commitNewItem() {
        let text = newItemText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !list.isArchived else { return }
        let item = UserListItem()
        item.text = text
        item.order = list.nextItemOrder
        let now = Date()
        item.createdAt = now
        item.updatedAt = now
        item.list = list
        modelContext.insert(item)
        list.updatedAt = now
        try? modelContext.save()
        newItemText = ""
        remindersSyncService?.triggerReconcile()
    }

    private func toggleItem(_ item: UserListItem) {
        guard list.kind == .checklist else { return }
        let now = Date()
        item.isCompleted.toggle()
        item.completedAt = item.isCompleted ? now : nil
        item.updatedAt = now
        list.updatedAt = now
        try? modelContext.save()
        remindersSyncService?.triggerReconcile()
    }

    private func removeItem(_ item: UserListItem) {
        // Capture EK identifier before deleting locally so the sync service can remove
        // the paired reminder; otherwise reconcile would re-import the orphan.
        let ekIdentifier = item.eventKitIdentifier
        let svc = remindersSyncService
        Task { @MainActor in
            await svc?.deleteEKReminder(eventKitIdentifier: ekIdentifier)
        }
        list.updatedAt = Date()
        modelContext.delete(item)
        try? modelContext.save()
        pendingItemRemoval = nil
        remindersSyncService?.triggerReconcile()
    }

    private func moveItems(from source: IndexSet, to destination: Int) {
        var items = sortedItems
        items.move(fromOffsets: source, toOffset: destination)
        let now = Date()
        for (index, item) in items.enumerated() {
            item.order = index
            item.updatedAt = now
        }
        list.updatedAt = now
        try? modelContext.save()
    }

    private func archiveList() {
        let now = Date()
        list.isArchived = true
        list.archivedAt = now
        list.updatedAt = now
        try? modelContext.save()
        remindersSyncService?.triggerReconcile()
    }

    private func restoreList() {
        let now = Date()
        list.isArchived = false
        list.archivedAt = nil
        list.updatedAt = now
        try? modelContext.save()
        remindersSyncService?.triggerReconcile()
    }
}

#Preview {
    ListsView()
}
