import SwiftData
import SwiftUI

/// Edit all Reminders-parity fields on a single `UserListItem` — text, notes, priority,
/// due date (with optional time), URL. Saving fires the same path as inline edits so
/// `RemindersSyncService.triggerReconcile` runs automatically through the SwiftData
/// observer chain (the row's `updatedAt` is bumped, sync picks it up next pass).
struct UserListItemDetailSheet: View {
    @Bindable var item: UserListItem
    let modelContainer: ModelContainer
    let remindersSyncService: RemindersSyncService?
    let onClose: () -> Void

    /// Live SwiftData context inherited from the surrounding view. Save mutates the
    /// passed `item` in place so the row updates without waiting for an external
    /// merge — same fix as `UserListDetail` (4.8d follow-up).
    @Environment(\.modelContext) private var modelContext

    @State private var draftText: String
    @State private var draftNotes: String
    @State private var draftPriority: Int
    @State private var draftHasDueDate: Bool
    @State private var draftDueDate: Date
    @State private var draftHasTime: Bool
    @State private var draftURLString: String

    init(
        item: UserListItem,
        modelContainer: ModelContainer,
        remindersSyncService: RemindersSyncService?,
        onClose: @escaping () -> Void
    ) {
        self.item = item
        self.modelContainer = modelContainer
        self.remindersSyncService = remindersSyncService
        self.onClose = onClose
        _draftText = State(initialValue: item.text)
        _draftNotes = State(initialValue: item.notes ?? "")
        _draftPriority = State(initialValue: item.priority)
        _draftHasDueDate = State(initialValue: item.dueDate != nil)
        _draftDueDate = State(initialValue: item.dueDate ?? Calendar.current.startOfDay(for: Date()))
        _draftHasTime = State(initialValue: item.hasTime)
        _draftURLString = State(initialValue: item.urlString ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Edit item").font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            Divider()
            Form {
                Section {
                    TextField("Item", text: $draftText, axis: .vertical)
                        .lineLimit(1...3)
                }
                Section("Notes") {
                    TextField("Long-form notes", text: $draftNotes, axis: .vertical)
                        .lineLimit(2...6)
                }
                Section("Priority") {
                    Picker("Priority", selection: $draftPriority) {
                        Text("None").tag(0)
                        Text("Low").tag(1)
                        Text("Medium").tag(5)
                        Text("High").tag(9)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section("Due date") {
                    Toggle("Has due date", isOn: $draftHasDueDate)
                    if draftHasDueDate {
                        DatePicker(
                            "Due",
                            selection: $draftDueDate,
                            displayedComponents: draftHasTime ? [.date, .hourAndMinute] : [.date]
                        )
                        Toggle("Specific time", isOn: $draftHasTime)
                    }
                }
                Section("URL") {
                    TextField("https://…", text: $draftURLString)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 560)
    }

    private func save() {
        let now = Date()
        item.text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = draftNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        item.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        item.priority = max(0, min(9, draftPriority))
        if draftHasDueDate {
            item.dueDate = draftDueDate
            item.hasTime = draftHasTime
        } else {
            item.dueDate = nil
            item.hasTime = false
        }
        let trimmedURL = draftURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        item.urlString = trimmedURL.isEmpty ? nil : trimmedURL
        item.updatedAt = now
        item.list?.updatedAt = now
        try? modelContext.save()
        remindersSyncService?.triggerReconcile()
        onClose()
    }
}
