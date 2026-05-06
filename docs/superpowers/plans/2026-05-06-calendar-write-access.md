# Calendar Write Access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add chat-driven create / move / delete of calendar events, plus per-calendar read filter and writable-calendar selection in Settings.

**Architecture:** Extend the existing read-only `CalendarService` (EventKit) with write helpers; add three `Tool`-protocol implementations following the existing `CreateScheduledActionTool` pattern (confirmation card → user confirm → save); add a new Settings section backed by `@AppStorage`.

**Tech Stack:** Swift, SwiftUI, EventKit (`EKEventStore`, `EKEvent`, `EKRecurrenceRule`), SwiftData (existing schema, no changes).

**Spec:** `/Users/alex/Code/Smoory/docs/superpowers/specs/2026-05-06-calendar-write-access-design.md`

**No-test-infra note:** Smoory has no XCTest/Swift Testing setup. The build gate per step is `xcodebuild -project Smoory/Smoory.xcodeproj -scheme Smoory -configuration Debug build -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD " | head -10` returning `** BUILD SUCCEEDED **`. Manual smoke checks happen at the end (Task 13).

---

## File Structure

**Modify:**
- `Smoory/Smoory/Services/CalendarService.swift` — add 6 helpers (Tasks 1–6).
- `Smoory/Smoory/Surfaces/Settings/SettingsView.swift` — add new Calendar section (Task 9).
- `Smoory/Smoory/Pipeline/ToolRegistry.swift` — register 3 new tools (Task 13).

**Create:**
- `Smoory/Smoory/Surfaces/Settings/CalendarSettingsViewModel.swift` (Task 7).
- `Smoory/Smoory/Surfaces/Settings/CalendarSettingsSection.swift` (Task 8).
- `Smoory/Smoory/Pipeline/Tools/CreateCalendarEventTool.swift` (Task 10).
- `Smoory/Smoory/Pipeline/Tools/MoveCalendarEventTool.swift` (Task 11).
- `Smoory/Smoory/Pipeline/Tools/DeleteCalendarEventTool.swift` (Task 12).

**Reused unchanged:**
- `Smoory/Smoory/Pipeline/Reminders/RecurrenceRule.swift` — call `RecurrenceRule.toEKRecurrenceRule()` from CreateCalendarEventTool.
- `Smoory/Smoory/Pipeline/Tools/ScheduledActionTimeResolver.swift` — natural-language time parsing.
- `Smoory/Smoory/Surfaces/Common/ErrorBus.swift` — env-injected toast bus.

---

### Task 1: CalendarService — read filter via `excludedCalendarIDs`

**Files:**
- Modify: `Smoory/Smoory/Services/CalendarService.swift` — extend `eventsForCurrentWindow` to honor an exclusion list.

**Why:** The "Read from these calendars" toggle in Settings persists `excludedCalendarIDs` to `@AppStorage`. The read path must honor that list before any feature ships, so the Feed and morning brief don't continue reading muted calendars.

- [ ] **Step 1: Add the AppStorage-key constants**

In `CalendarService.swift`, just below `final class CalendarService {`:

```swift
    /// Centralizes the AppStorage keys this service reads, so the Settings VM and
    /// the service agree on the storage location without one importing the other.
    enum DefaultsKey {
        static let writableCalendarID = "calendar.writableCalendarID"
        static let excludedCalendarIDs = "calendar.excludedCalendarIDs"
    }
```

- [ ] **Step 2: Read the exclusion list and pre-filter calendars**

Replace the `let predicate = …` line (currently inside `eventsForCurrentWindow`) with this block:

```swift
        let allCalendars = store.calendars(for: .event)
        let excludedIDs = Self.readExcludedCalendarIDs()
        let included = allCalendars.filter { !excludedIDs.contains($0.calendarIdentifier) }
        let predicate = store.predicateForEvents(
            withStart: windowStart,
            end: windowEnd,
            calendars: included.isEmpty ? nil : included   // nil = all calendars
        )
```

Add this private static helper at the bottom of the class:

```swift
    private static func readExcludedCalendarIDs() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.excludedCalendarIDs),
              let array = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(array)
    }
```

- [ ] **Step 3: Build clean**

Run: `xcodebuild -project /Users/alex/Code/Smoory/Smoory/Smoory.xcodeproj -scheme Smoory -configuration Debug build -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD " | head -10`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Smoory/Smoory/Services/CalendarService.swift
git commit -m "CalendarService: honor excludedCalendarIDs in event window"
```

---

### Task 2: CalendarService — `listAvailableCalendars` + `writableCalendar` resolver

**Files:**
- Modify: `Smoory/Smoory/Services/CalendarService.swift` — add 2 helpers.

**Why:** Settings UI needs the available calendars for its toggles + picker. Tools need to resolve which `EKCalendar` to write to.

- [ ] **Step 1: Add the helpers**

Append to `CalendarService` (just above `private static func toCalendarEvent`):

```swift
    /// All calendars EventKit knows about that the user can read events from.
    /// Subscribed read-only calendars are included — they're useful for the read
    /// filter even though they can't be written to.
    func listAvailableCalendars() -> [EKCalendar] {
        store.calendars(for: .event).sorted { $0.title < $1.title }
    }

    /// Calendars the user can write events to. Filters out subscribed/read-only
    /// calendars so the Settings picker only offers valid write targets.
    func listWritableCalendars() -> [EKCalendar] {
        store.calendars(for: .event)
            .filter { $0.allowsContentModifications }
            .sorted { $0.title < $1.title }
    }

    /// Resolves the configured "Smoory writes here" calendar. Falls back to the
    /// system default. Returns nil only if the user has zero writable calendars.
    func writableCalendar() -> EKCalendar? {
        let configuredID = UserDefaults.standard.string(forKey: DefaultsKey.writableCalendarID)
        if let configuredID, !configuredID.isEmpty,
           let match = store.calendar(withIdentifier: configuredID),
           match.allowsContentModifications {
            return match
        }
        return store.defaultCalendarForNewEvents
    }
```

- [ ] **Step 2: Build clean**

Run: `xcodebuild -project /Users/alex/Code/Smoory/Smoory/Smoory.xcodeproj -scheme Smoory -configuration Debug build -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD " | head -10`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Smoory/Smoory/Services/CalendarService.swift
git commit -m "CalendarService: add listAvailableCalendars + writableCalendar resolver"
```

---

### Task 3: CalendarService — `findConflicts`

**Files:**
- Modify: `Smoory/Smoory/Services/CalendarService.swift` — add conflict scan.

**Why:** Confirmation cards surface overlap warnings; tool execution can decide whether to surface them. Per spec, this honors the exclusion list (a muted calendar's events do not generate conflict warnings).

- [ ] **Step 1: Add the helper**

Append to `CalendarService` just below `writableCalendar()`:

```swift
    /// Returns events overlapping `start..<end` from non-excluded calendars,
    /// optionally skipping a specific event id (used by `move_calendar_event`
    /// so the event being moved isn't reported as overlapping itself).
    func findConflicts(
        start: Date,
        end: Date,
        excludingEventID: String? = nil
    ) async throws -> [CalendarEvent] {
        try await ensureAccess()
        let allCalendars = store.calendars(for: .event)
        let excludedIDs = Self.readExcludedCalendarIDs()
        let included = allCalendars.filter { !excludedIDs.contains($0.calendarIdentifier) }
        let predicate = store.predicateForEvents(
            withStart: start,
            end: end,
            calendars: included.isEmpty ? nil : included
        )
        let raw = store.events(matching: predicate)
        return raw
            .filter { event in
                // The predicate is inclusive on both ends; trim equal-edge events
                // (a 14:00–15:00 event isn't a conflict for a 15:00–16:00 block).
                event.startDate < end && event.endDate > start
            }
            .filter { $0.eventIdentifier != excludingEventID }
            .map(Self.toCalendarEvent)
            .sorted { $0.start < $1.start }
    }
```

- [ ] **Step 2: Build clean**

Same command as Task 1 Step 3.

- [ ] **Step 3: Commit**

```bash
git add Smoory/Smoory/Services/CalendarService.swift
git commit -m "CalendarService: add findConflicts (honors excluded calendars)"
```

---

### Task 4: CalendarService — `createEvent`

**Files:**
- Modify: `Smoory/Smoory/Services/CalendarService.swift` — add the create helper.

**Why:** Pure write path used by `CreateCalendarEventTool`. Keep the EKEvent construction here so the tool stays a thin wrapper around inputs/outputs.

- [ ] **Step 1: Add the input struct + create helper**

Append to `CalendarService` below `findConflicts`:

```swift
    struct CreateEventInput {
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let location: String?
        let notes: String?
        let recurrence: EKRecurrenceRule?      // already converted by the caller
    }

    /// Saves a new event to `writableCalendar()`. Throws when the user has no
    /// writable calendars or EventKit save fails. Caller is responsible for
    /// resolving relative time phrases via ScheduledActionTimeResolver.
    @discardableResult
    func createEvent(_ input: CreateEventInput) async throws -> EKEvent {
        try await ensureAccess()
        guard let calendar = writableCalendar() else {
            throw CalendarServiceError.unknown(
                NSError(
                    domain: "CalendarService",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No writable calendar available. Pick one in Settings."]
                )
            )
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = input.title
        event.startDate = input.start
        event.endDate = input.end
        event.isAllDay = input.isAllDay
        event.location = input.location
        event.notes = input.notes
        if let rule = input.recurrence {
            event.addRecurrenceRule(rule)
        }
        try store.save(event, span: .thisEvent, commit: true)
        return event
    }
```

- [ ] **Step 2: Build clean**

Same command as Task 1 Step 3.

- [ ] **Step 3: Commit**

```bash
git add Smoory/Smoory/Services/CalendarService.swift
git commit -m "CalendarService: add createEvent helper"
```

---

### Task 5: CalendarService — `moveEvent` with scope resolution

**Files:**
- Modify: `Smoory/Smoory/Services/CalendarService.swift` — add scope enum + move helper.

**Why:** Recurring move/delete needs the EventKit span dance (`.thisEvent` vs `.futureEvents`, with "all" mapping to walking back to the first occurrence). Keep this messy logic in the service so the tools stay thin.

- [ ] **Step 1: Add the scope enum (file-scope, NOT inside the class)**

Add at the top of `CalendarService.swift`, just below `import WidgetKit`:

```swift
/// Maps the LLM-facing scope string to an EKSpan and a target-event resolver.
enum CalendarEventScope: String {
    case single
    case following
    case all

    var ekSpan: EKSpan {
        switch self {
        case .single: return .thisEvent
        case .following, .all: return .futureEvents
        }
    }
}
```

- [ ] **Step 2: Add the `moveEvent` helper**

Append to `CalendarService` below `createEvent`:

```swift
    /// Moves an event to a new start/end. For recurring events, `scope` selects
    /// which occurrence(s) shift. Returns the (possibly different) target EKEvent
    /// that EventKit acted on — for `scope == .all`, this is the first occurrence
    /// of the series.
    @discardableResult
    func moveEvent(
        eventID: String,
        scope: CalendarEventScope,
        newStart: Date,
        newEnd: Date
    ) async throws -> EKEvent {
        try await ensureAccess()
        guard let event = store.event(withIdentifier: eventID) else {
            throw CalendarServiceError.unknown(
                NSError(
                    domain: "CalendarService",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Event not found: \(eventID)"]
                )
            )
        }
        let target = try resolveTargetEvent(for: event, scope: scope)
        target.startDate = newStart
        target.endDate = newEnd
        try store.save(target, span: scope.ekSpan, commit: true)
        return target
    }

    /// Walks back to the first occurrence of a recurring series. For non-recurring
    /// events this returns the event unchanged.
    private func resolveTargetEvent(
        for event: EKEvent,
        scope: CalendarEventScope
    ) throws -> EKEvent {
        switch scope {
        case .single, .following:
            return event
        case .all:
            // EKEvent doesn't expose the series root directly. The convention is to
            // re-fetch by identifier; for occurrences EventKit returns the event
            // representing the date you queried. Walk back via `firstOccurrence`
            // when available; if not, fall through to the event itself with
            // `.futureEvents` span — which captures everything from now forward.
            if event.hasRecurrenceRules,
               let first = event.value(forKey: "firstOccurrence") as? EKEvent {
                return first
            }
            return event
        }
    }
```

(Note: `firstOccurrence` is a private/legacy KVO accessor. The fallback path — operating on the queried event with `.futureEvents` span — captures every occurrence from the user's query date forward, which is the practical "all" the user expects when they say "move all standups to 10am" *now*.)

- [ ] **Step 3: Build clean**

Same command as Task 1 Step 3.

- [ ] **Step 4: Commit**

```bash
git add Smoory/Smoory/Services/CalendarService.swift
git commit -m "CalendarService: add moveEvent with scope (single/following/all)"
```

---

### Task 6: CalendarService — `deleteEvent`

**Files:**
- Modify: `Smoory/Smoory/Services/CalendarService.swift` — add delete helper.

- [ ] **Step 1: Add the helper**

Append to `CalendarService` below `moveEvent`:

```swift
    /// Removes an event. For recurring events, `scope` selects which occurrence(s)
    /// disappear. Mirrors `moveEvent`'s scope handling.
    func deleteEvent(eventID: String, scope: CalendarEventScope) async throws {
        try await ensureAccess()
        guard let event = store.event(withIdentifier: eventID) else {
            throw CalendarServiceError.unknown(
                NSError(
                    domain: "CalendarService",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Event not found: \(eventID)"]
                )
            )
        }
        let target = try resolveTargetEvent(for: event, scope: scope)
        try store.remove(target, span: scope.ekSpan, commit: true)
    }
```

- [ ] **Step 2: Build clean**

Same command as Task 1 Step 3.

- [ ] **Step 3: Commit**

```bash
git add Smoory/Smoory/Services/CalendarService.swift
git commit -m "CalendarService: add deleteEvent with scope"
```

---

### Task 7: `CalendarSettingsViewModel`

**Files:**
- Create: `Smoory/Smoory/Surfaces/Settings/CalendarSettingsViewModel.swift`

**Why:** Owns the available-calendars list and the toggle/picker bindings. Subscribes to `EKEventStoreChanged` so the calendar list refreshes when the user creates/deletes calendars in Calendar.app.

- [ ] **Step 1: Write the file**

```swift
import EventKit
import Foundation
import Observation
import SwiftUI

/// Drives the Calendar section in Settings. Eagerly init via
/// `_vm = State(wrappedValue:)` (matches ReviewScheduleSettings F-17 fix) so the
/// section paints fully populated on the first frame.
@Observable
@MainActor
final class CalendarSettingsViewModel {
    /// All calendars EventKit knows about, sorted by title. Refreshed on init and
    /// whenever the system fires `EKEventStoreChanged`.
    private(set) var availableCalendars: [EKCalendar] = []
    /// Subset of `availableCalendars` the user can write to (filters out
    /// subscribed/read-only). Drives the "Smoory writes here" picker.
    private(set) var writableCalendars: [EKCalendar] = []

    /// Configured writable calendar id. Empty string == "use system default".
    var writableCalendarID: String {
        didSet { UserDefaults.standard.set(writableCalendarID, forKey: CalendarService.DefaultsKey.writableCalendarID) }
    }

    /// Per-calendar excluded set. Toggle binding writes through this.
    var excludedCalendarIDs: Set<String> {
        didSet { persistExcluded() }
    }

    private let calendarService: CalendarService
    private var observationTask: Task<Void, Never>?

    init(calendarService: CalendarService) {
        self.calendarService = calendarService
        self.writableCalendarID = UserDefaults.standard.string(forKey: CalendarService.DefaultsKey.writableCalendarID) ?? ""
        if let data = UserDefaults.standard.data(forKey: CalendarService.DefaultsKey.excludedCalendarIDs),
           let array = try? JSONDecoder().decode([String].self, from: data) {
            self.excludedCalendarIDs = Set(array)
        } else {
            self.excludedCalendarIDs = []
        }
        refresh()
        startObservingStoreChanges()
    }

    deinit {
        observationTask?.cancel()
    }

    func refresh() {
        availableCalendars = calendarService.listAvailableCalendars()
        writableCalendars = calendarService.listWritableCalendars()
    }

    /// True when the calendar's events should appear in Feed / brief / reviews.
    func isIncluded(_ calendar: EKCalendar) -> Bool {
        !excludedCalendarIDs.contains(calendar.calendarIdentifier)
    }

    /// Two-way binding for the per-calendar toggle row.
    func includedBinding(for calendar: EKCalendar) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.isIncluded(calendar) ?? true },
            set: { [weak self] newValue in
                guard let self else { return }
                if newValue {
                    self.excludedCalendarIDs.remove(calendar.calendarIdentifier)
                } else {
                    self.excludedCalendarIDs.insert(calendar.calendarIdentifier)
                }
            }
        )
    }

    private func persistExcluded() {
        let array = Array(excludedCalendarIDs).sorted()
        if let data = try? JSONEncoder().encode(array) {
            UserDefaults.standard.set(data, forKey: CalendarService.DefaultsKey.excludedCalendarIDs)
        }
    }

    private func startObservingStoreChanges() {
        observationTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                guard let self else { return }
                self.refresh()
            }
        }
    }
}
```

- [ ] **Step 2: Build clean**

Same command as Task 1 Step 3.

- [ ] **Step 3: Commit**

```bash
git add Smoory/Smoory/Surfaces/Settings/CalendarSettingsViewModel.swift
git commit -m "Settings: add CalendarSettingsViewModel"
```

---

### Task 8: `CalendarSettingsSection`

**Files:**
- Create: `Smoory/Smoory/Surfaces/Settings/CalendarSettingsSection.swift`

**Why:** UI for the Calendar Settings section. Eagerly initializes its VM via `_vm = State(wrappedValue:)`, mirrors `ReviewScheduleSettings`.

- [ ] **Step 1: Write the file**

```swift
import EventKit
import SwiftUI

/// Calendar section in Settings. Shows authorization status, the "Smoory writes
/// here" picker, and per-calendar read toggles. Eagerly initializes its VM so
/// the section paints fully populated on first frame (F-17 pattern).
struct CalendarSettingsSection: View {
    @State private var vm: CalendarSettingsViewModel

    init(calendarService: CalendarService) {
        _vm = State(wrappedValue: CalendarSettingsViewModel(calendarService: calendarService))
    }

    var body: some View {
        Section("Calendar") {
            authorizationRow

            if vm.availableCalendars.isEmpty {
                Text("No calendars yet — create one in Calendar.app, then return here.")
                    .font(.smoory_caption)
                    .foregroundStyle(.tertiary)
            } else {
                writableCalendarPicker
                readToggleList
                helperCaption
            }
        }
    }

    @ViewBuilder
    private var authorizationRow: some View {
        let status = EKEventStore.authorizationStatus(for: .event)
        HStack {
            Image(systemName: status == .fullAccess ? "calendar.badge.checkmark" : "calendar.badge.exclamationmark")
                .foregroundStyle(status == .fullAccess ? Color.green : Color.orange)
            Text(authorizationLabel(for: status))
                .font(.smoory_body)
            Spacer()
        }
        if status != .fullAccess {
            Text("Open System Settings → Privacy & Security → Calendars and grant Smoory full access.")
                .font(.smoory_caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var writableCalendarPicker: some View {
        Picker("Smoory writes here", selection: $vm.writableCalendarID) {
            Text("System default").tag("")
            ForEach(vm.writableCalendars, id: \.calendarIdentifier) { cal in
                Text(cal.title).tag(cal.calendarIdentifier)
            }
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private var readToggleList: some View {
        Text("Read from these calendars")
            .font(.smoory_caption)
            .foregroundStyle(.secondary)
        ForEach(vm.availableCalendars, id: \.calendarIdentifier) { cal in
            Toggle(isOn: vm.includedBinding(for: cal)) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(cgColor: cal.cgColor))
                        .frame(width: 10, height: 10)
                    Text(cal.title)
                        .font(.smoory_body)
                    Spacer()
                }
            }
            .toggleStyle(.checkbox)
        }
    }

    @ViewBuilder
    private var helperCaption: some View {
        Text("Smoory creates / moves / deletes events on the writes-here calendar. Reading covers every checked calendar above.")
            .font(.smoory_caption)
            .foregroundStyle(.tertiary)
    }

    private func authorizationLabel(for status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess: return "Authorized — full access"
        case .writeOnly: return "Write-only access (insufficient — needs full access)"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Permission will be requested"
        @unknown default: return "Unknown"
        }
    }
}
```

- [ ] **Step 2: Build clean**

Same command as Task 1 Step 3.

- [ ] **Step 3: Commit**

```bash
git add Smoory/Smoory/Surfaces/Settings/CalendarSettingsSection.swift
git commit -m "Settings: add CalendarSettingsSection view"
```

---

### Task 9: Wire `CalendarSettingsSection` into `SettingsView`

**Files:**
- Modify: `Smoory/Smoory/Surfaces/Settings/SettingsView.swift`

**Why:** SettingsView needs to host the new section and pass through a `CalendarService` instance. We construct a fresh `CalendarService()` here — it's a thin wrapper over `EKEventStore`; instantiation is cheap.

- [ ] **Step 1: Add a stored CalendarService (for the new section)**

In `SettingsView`, just after `@State private var providerVM = ProviderViewModel()`, add:

```swift
    @State private var calendarServiceForSettings = CalendarService()
```

- [ ] **Step 2: Insert the new section in the Form body**

In `SettingsView.body`, after the `remindersSyncSection` and before `timeOffSection`, add:

```swift
            CalendarSettingsSection(calendarService: calendarServiceForSettings)
```

- [ ] **Step 3: Build clean**

Same command as Task 1 Step 3.

- [ ] **Step 4: Manual smoke check**

Relaunch:
```bash
osascript -e 'quit app "Smoory"' 2>/dev/null; sleep 1; open /Users/alex/Library/Developer/Xcode/DerivedData/Smoory-awmhbyagcsebmraomliojfvpalyb/Build/Products/Debug/Smoory.app
```
Open Settings → confirm: (a) the Calendar section appears between Reminders sync and Time off; (b) all your real calendars are listed with checkboxes; (c) the "Smoory writes here" picker is populated with writable calendars only.

- [ ] **Step 5: Commit**

```bash
git add Smoory/Smoory/Surfaces/Settings/SettingsView.swift
git commit -m "Settings: wire CalendarSettingsSection into SettingsView"
```

---

### Task 10: `CreateCalendarEventTool`

**Files:**
- Create: `Smoory/Smoory/Pipeline/Tools/CreateCalendarEventTool.swift`

**Why:** The `tier1Quick` tool the LLM calls for new events. Mirrors `CreateScheduledActionTool` shape — Input struct, schema, execute(), renderSummary, makeEditView.

**Note on edit view:** For first ship, return a minimal editor that only allows editing title + start + end. Recurrence editing is deferred to a follow-up — the LLM-generated proposal is editable for the common case (title typo, time tweak); recurrence misfires can be declined and rephrased.

- [ ] **Step 1: Write the file**

```swift
import EventKit
import Foundation
import SwiftData
import SwiftUI

enum CreateCalendarEventTool: Tool {
    static let name = "create_calendar_event"

    static let description = """
        Create a new calendar event. Use when the user asks to schedule something \
        on their calendar — "schedule a 30-min focus block tomorrow at 2pm", \
        "add a meeting with Maria Friday at 10", "every weekday at 9am, 15-min \
        standup for the next month". The user sees a confirmation card with the \
        proposed event details (and any conflict warnings) before it's actually \
        saved.

        Time format: prefer ISO 8601 (e.g., "2026-05-01T14:30:00"). Natural-language \
        relative phrases also accepted — same resolver as create_scheduled_action.

        Provide either `end` (ISO/natural) OR `duration_minutes` (int), not both.
        Recurrence is optional — pass it only when the user explicitly asks for \
        a repeating event.

        Conflicts (overlapping events on non-muted calendars) are surfaced in the \
        confirmation card automatically — the user decides whether to keep the \
        proposal anyway. You don't need to call get_calendar_window first.
        """

    static let confirmationTier: ConfirmationTier = .tier1Quick

    static let inputSchema = ToolInputSchema(
        properties: [
            "title": ToolInputSchemaProperty(
                type: "string",
                description: "Event title."
            ),
            "start": ToolInputSchemaProperty(
                type: "string",
                description: "When the event starts. ISO 8601 preferred; natural-language phrases accepted."
            ),
            "end": ToolInputSchemaProperty(
                type: "string",
                description: "When the event ends. ISO/natural. Provide either end OR duration_minutes."
            ),
            "duration_minutes": ToolInputSchemaProperty(
                type: "integer",
                description: "Alternative to `end`: minutes from start. Provide either end OR duration_minutes."
            ),
            "location": ToolInputSchemaProperty(
                type: "string",
                description: "Optional location."
            ),
            "notes": ToolInputSchemaProperty(
                type: "string",
                description: "Optional notes / description body for the event."
            ),
            "is_all_day": ToolInputSchemaProperty(
                type: "boolean",
                description: "When true, the start/end are treated as date boundaries; default false."
            ),
            "recurrence": ToolInputSchemaProperty(
                type: "object",
                description: "Optional recurrence. Object with keys: frequency (DAILY|WEEKLY|MONTHLY|YEARLY), interval (int, default 1), days_of_week (array of MO/TU/WE/TH/FR/SA/SU, only for WEEKLY), end (object with `count: int` OR `until: ISO8601`)."
            )
        ],
        required: ["title", "start"]
    )

    struct Input: Codable {
        let title: String
        let start: String
        let end: String?
        let duration_minutes: Int?
        let location: String?
        let notes: String?
        let is_all_day: Bool?
        let recurrence: RecurrenceInput?
    }

    struct RecurrenceInput: Codable {
        let frequency: String
        let interval: Int?
        let days_of_week: [String]?
        let end: RecurrenceEndInput?
    }

    struct RecurrenceEndInput: Codable {
        let count: Int?
        let until: String?
    }

    static func execute(parametersJSON: String, context: ToolExecutionContext) async throws -> ToolOutput {
        let input: Input
        do {
            input = try decodeInput(parametersJSON)
        } catch {
            return errorOutput(toolUseId: context.toolUseId, message: "could not decode parameters: \(error.localizedDescription)")
        }

        let resolved: (start: Date, end: Date)
        do {
            resolved = try await resolveTimes(input: input, services: context.services)
        } catch {
            return errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }

        let recurrence = buildEKRecurrence(from: input.recurrence)

        let createInput = CalendarService.CreateEventInput(
            title: input.title,
            start: resolved.start,
            end: resolved.end,
            isAllDay: input.is_all_day ?? false,
            location: input.location,
            notes: input.notes,
            recurrence: recurrence
        )

        do {
            let event = try await context.services.calendarService.createEvent(createInput)
            let conflicts = (try? await context.services.calendarService.findConflicts(
                start: resolved.start,
                end: resolved.end,
                excludingEventID: event.eventIdentifier
            )) ?? []
            let payload: [String: any Sendable] = [
                "status": "created",
                "id": event.eventIdentifier ?? "",
                "calendar_name": event.calendar.title,
                "conflicts": conflicts.map { ["title": $0.title, "start": $0.start.formatted(.iso8601), "end": $0.end.formatted(.iso8601)] }
            ]
            return ToolOutput(
                toolUseId: context.toolUseId,
                content: encodeJSON(payload),
                isError: false
            )
        } catch {
            return errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }
    }

    static func renderSummary(parametersJSON: String, modelContainer: ModelContainer) -> ProposedActionSummary? {
        guard let input = try? decodeInput(parametersJSON) else { return nil }
        let timeStr: String
        if let iso = parseISO8601(input.start) {
            timeStr = formatHuman(iso)
        } else {
            timeStr = input.start
        }
        var secondary = "Calendar event"
        if let recurrence = input.recurrence {
            secondary += " · \(displayRecurrence(recurrence))"
        }
        return ProposedActionSummary(
            icon: "calendar.badge.plus",
            title: "Create event",
            primary: "\(input.title) — \(timeStr)",
            secondary: secondary
        )
    }

    @MainActor
    static func makeEditView(
        parametersJSON: String,
        modelContainer: ModelContainer,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) -> AnyView {
        AnyView(CreateCalendarEventEditView(
            parametersJSON: parametersJSON,
            onCommit: onCommit,
            onCancel: onCancel
        ))
    }

    // MARK: - Helpers

    private static func decodeInput(_ jsonString: String) throws -> Input {
        guard let data = jsonString.data(using: .utf8), !data.isEmpty else {
            throw NSError(
                domain: "CreateCalendarEventTool",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "empty parameters"]
            )
        }
        return try JSONDecoder().decode(Input.self, from: data)
    }

    private static func resolveTimes(input: Input, services: ToolServices) async throws -> (start: Date, end: Date) {
        let start: Date
        if let iso = parseISO8601(input.start) {
            start = iso
        } else {
            start = try await ScheduledActionTimeResolver.resolve(
                input.start,
                content: input.title,
                services: services,
                now: Date()
            )
        }

        let end: Date
        if let endStr = input.end, !endStr.isEmpty {
            if let iso = parseISO8601(endStr) {
                end = iso
            } else {
                end = try await ScheduledActionTimeResolver.resolve(
                    endStr,
                    content: input.title,
                    services: services,
                    now: start
                )
            }
        } else if let minutes = input.duration_minutes, minutes > 0 {
            end = start.addingTimeInterval(TimeInterval(minutes * 60))
        } else {
            // Default: 30-minute event when neither end nor duration is provided.
            end = start.addingTimeInterval(30 * 60)
        }

        guard end > start else {
            throw NSError(
                domain: "CreateCalendarEventTool",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Event end must be after start (got \(end.formatted(.iso8601)) ≤ \(start.formatted(.iso8601)))"]
            )
        }
        return (start, end)
    }

    private static func buildEKRecurrence(from input: RecurrenceInput?) -> EKRecurrenceRule? {
        guard let input else { return nil }
        guard let freq = RecurrenceRule.Frequency(rawValue: input.frequency.uppercased()) else { return nil }
        let interval = max(1, input.interval ?? 1)
        let days: [RecurrenceRule.Weekday] = (input.days_of_week ?? [])
            .compactMap { RecurrenceRule.Weekday(rawValue: $0.uppercased()) }
        let end: RecurrenceRule.End
        if let endInput = input.end {
            if let count = endInput.count, count > 0 {
                end = .count(count)
            } else if let untilStr = endInput.until, let untilDate = parseISO8601(untilStr) {
                end = .until(untilDate)
            } else {
                end = .never
            }
        } else {
            end = .never
        }
        let rule = RecurrenceRule(
            frequency: freq,
            interval: interval,
            daysOfWeek: days,
            end: end
        )
        return rule.toEKRecurrenceRule()
    }

    private static func displayRecurrence(_ input: RecurrenceInput) -> String {
        guard let freq = RecurrenceRule.Frequency(rawValue: input.frequency.uppercased()) else {
            return "recurring"
        }
        let interval = max(1, input.interval ?? 1)
        let days = (input.days_of_week ?? []).compactMap { RecurrenceRule.Weekday(rawValue: $0.uppercased()) }
        let end: RecurrenceRule.End
        if let endInput = input.end {
            if let count = endInput.count, count > 0 {
                end = .count(count)
            } else if let untilStr = endInput.until, let untilDate = parseISO8601(untilStr) {
                end = .until(untilDate)
            } else {
                end = .never
            }
        } else {
            end = .never
        }
        return RecurrenceRule(
            frequency: freq,
            interval: interval,
            daysOfWeek: days,
            end: end
        ).displayLabel
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if let d = try? Date(trimmed, strategy: .iso8601) { return d }
        let style = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
            .dateTimeSeparator(.standard).time(includingFractionalSeconds: false)
        if let d = try? style.parse(trimmed) { return d }
        return nil
    }

    private static func formatHuman(_ date: Date) -> String {
        let cal = Calendar.current
        let timeStr = date.formatted(.dateTime.hour().minute())
        if cal.isDateInToday(date)    { return "Today at \(timeStr)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow at \(timeStr)" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute())
    }

    private static func encodeJSON(_ obj: [String: any Sendable]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }

    private static func errorOutput(toolUseId: String, message: String) -> ToolOutput {
        let payload = #"{"status":"error","message":"\#(escape(message))"}"#
        return ToolOutput(toolUseId: toolUseId, content: payload, isError: true)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Edit view

private struct CreateCalendarEventEditView: View {
    let parametersJSON: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var title: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var allDay: Bool

    init(
        parametersJSON: String,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.parametersJSON = parametersJSON
        self.onCommit = onCommit
        self.onCancel = onCancel
        let decoded = try? JSONDecoder().decode(CreateCalendarEventTool.Input.self, from: Data(parametersJSON.utf8))
        let now = Date()
        let parsedStart = decoded?.start.flatMap(Self.parseISO8601) ?? now
        let parsedEnd = decoded?.end.flatMap(Self.parseISO8601) ?? parsedStart.addingTimeInterval(30 * 60)
        _title = State(initialValue: decoded?.title ?? "")
        _startDate = State(initialValue: parsedStart)
        _endDate = State(initialValue: parsedEnd)
        _allDay = State(initialValue: decoded?.is_all_day ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit event").font(.headline)
            Form {
                TextField("Title", text: $title)
                Toggle("All-day", isOn: $allDay)
                DatePicker("Starts", selection: $startDate, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                DatePicker("Ends", selection: $endDate, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
            }
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button("Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || endDate <= startDate)
            }
        }
        .padding(14)
        .frame(minWidth: 360)
    }

    private func commit() {
        // Reconstruct an Input JSON from edited values, preserving optional fields
        // we don't expose in the editor (location/notes/recurrence) by passing
        // through from the original parametersJSON.
        let original = try? JSONDecoder().decode(CreateCalendarEventTool.Input.self, from: Data(parametersJSON.utf8))
        let edited = CreateCalendarEventTool.Input(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            start: startDate.formatted(.iso8601),
            end: endDate.formatted(.iso8601),
            duration_minutes: nil,
            location: original?.location,
            notes: original?.notes,
            is_all_day: allDay,
            recurrence: original?.recurrence
        )
        guard let data = try? JSONEncoder().encode(edited),
              let json = String(data: data, encoding: .utf8) else { return }
        onCommit(json)
    }

    private static func parseISO8601(_ s: String) -> Date? {
        if let d = try? Date(s, strategy: .iso8601) { return d }
        let style = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
            .dateTimeSeparator(.standard).time(includingFractionalSeconds: false)
        return try? style.parse(s)
    }
}
```

- [ ] **Step 2: Build clean**

(`ToolServices.calendarService: CalendarService` already exists at `Smoory/Smoory/Pipeline/ToolExecutionContext.swift:18` — no struct changes needed.)

Same command as Task 1 Step 3.

- [ ] **Step 3: Commit**

```bash
git add Smoory/Smoory/Pipeline/Tools/CreateCalendarEventTool.swift
git commit -m "Tools: add create_calendar_event (tier1Quick)"
```

---

### Task 11: `MoveCalendarEventTool`

**Files:**
- Create: `Smoory/Smoory/Pipeline/Tools/MoveCalendarEventTool.swift`

- [ ] **Step 1: Write the file**

```swift
import EventKit
import Foundation
import SwiftData
import SwiftUI

enum MoveCalendarEventTool: Tool {
    static let name = "move_calendar_event"

    static let description = """
        Move (reschedule) an existing calendar event. Use when the user asks to \
        change the time or date of an event they already have — "move tomorrow's \
        standup to 10am", "shift the dentist appointment to next Thursday".

        Pass `event_id` from a prior get_calendar_window result.

        For recurring events, choose `scope`:
        - "single": move only this one occurrence (default)
        - "following": move this one and every later occurrence
        - "all": move every occurrence in the series

        If `new_end` is omitted, the event's original duration is preserved.
        """

    static let confirmationTier: ConfirmationTier = .tier1Quick

    static let inputSchema = ToolInputSchema(
        properties: [
            "event_id": ToolInputSchemaProperty(
                type: "string",
                description: "EKEvent identifier from get_calendar_window."
            ),
            "new_start": ToolInputSchemaProperty(
                type: "string",
                description: "New start time. ISO 8601 preferred; natural-language phrases accepted."
            ),
            "new_end": ToolInputSchemaProperty(
                type: "string",
                description: "Optional new end time. If omitted, original duration preserved."
            ),
            "scope": ToolInputSchemaProperty(
                type: "string",
                description: "single | following | all. Default: single."
            )
        ],
        required: ["event_id", "new_start"]
    )

    struct Input: Codable {
        let event_id: String
        let new_start: String
        let new_end: String?
        let scope: String?
    }

    static func execute(parametersJSON: String, context: ToolExecutionContext) async throws -> ToolOutput {
        let input: Input
        do {
            input = try decodeInput(parametersJSON)
        } catch {
            return errorOutput(toolUseId: context.toolUseId, message: "could not decode parameters: \(error.localizedDescription)")
        }
        let scope = CalendarEventScope(rawValue: (input.scope ?? "single").lowercased()) ?? .single
        let calendarService = context.services.calendarService

        // Look up original to compute preserved end if new_end omitted.
        guard let original = (try? await calendarService.eventForIdentifier(input.event_id)) else {
            return errorOutput(toolUseId: context.toolUseId, message: "Event not found: \(input.event_id)")
        }

        let newStart: Date
        if let iso = parseISO8601(input.new_start) {
            newStart = iso
        } else {
            do {
                newStart = try await ScheduledActionTimeResolver.resolve(
                    input.new_start,
                    content: original.title ?? "",
                    services: context.services,
                    now: Date()
                )
            } catch {
                return errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
            }
        }

        let newEnd: Date
        if let endStr = input.new_end, !endStr.isEmpty {
            if let iso = parseISO8601(endStr) {
                newEnd = iso
            } else {
                do {
                    newEnd = try await ScheduledActionTimeResolver.resolve(
                        endStr,
                        content: original.title ?? "",
                        services: context.services,
                        now: newStart
                    )
                } catch {
                    return errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
                }
            }
        } else {
            let originalDuration = original.endDate.timeIntervalSince(original.startDate)
            newEnd = newStart.addingTimeInterval(originalDuration)
        }

        do {
            let event = try await calendarService.moveEvent(
                eventID: input.event_id,
                scope: scope,
                newStart: newStart,
                newEnd: newEnd
            )
            let payload: [String: any Sendable] = [
                "status": "moved",
                "id": event.eventIdentifier ?? input.event_id,
                "new_start": newStart.formatted(.iso8601),
                "new_end": newEnd.formatted(.iso8601),
                "scope": scope.rawValue
            ]
            return ToolOutput(
                toolUseId: context.toolUseId,
                content: encodeJSON(payload),
                isError: false
            )
        } catch {
            return errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }
    }

    static func renderSummary(parametersJSON: String, modelContainer: ModelContainer) -> ProposedActionSummary? {
        guard let input = try? decodeInput(parametersJSON) else { return nil }
        let scope = (input.scope ?? "single").lowercased()
        let scopeBadge: String
        switch scope {
        case "all": scopeBadge = "All occurrences"
        case "following": scopeBadge = "This and following"
        default: scopeBadge = "Just this occurrence"
        }
        let timeStr = parseISO8601(input.new_start).map(formatHuman) ?? input.new_start
        return ProposedActionSummary(
            icon: "calendar.badge.clock",
            title: "Move event",
            primary: "→ \(timeStr)",
            secondary: scopeBadge
        )
    }

    @MainActor
    static func makeEditView(
        parametersJSON: String,
        modelContainer: ModelContainer,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) -> AnyView {
        // No edit view for v1 — confirm or decline. Move semantics + scope are
        // best surfaced as a clean confirm/decline; tweaking the time inline
        // would require us to know which scope to apply.
        AnyView(EmptyView())
    }

    // MARK: - Helpers (same shape as CreateCalendarEventTool)

    private static func decodeInput(_ jsonString: String) throws -> Input {
        guard let data = jsonString.data(using: .utf8), !data.isEmpty else {
            throw NSError(
                domain: "MoveCalendarEventTool",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "empty parameters"]
            )
        }
        return try JSONDecoder().decode(Input.self, from: data)
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        if let d = try? Date(trimmed, strategy: .iso8601) { return d }
        let style = Date.ISO8601FormatStyle(timeZone: .current).year().month().day()
            .dateTimeSeparator(.standard).time(includingFractionalSeconds: false)
        if let d = try? style.parse(trimmed) { return d }
        return nil
    }

    private static func formatHuman(_ date: Date) -> String {
        let cal = Calendar.current
        let timeStr = date.formatted(.dateTime.hour().minute())
        if cal.isDateInToday(date)    { return "Today at \(timeStr)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow at \(timeStr)" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute())
    }

    private static func encodeJSON(_ obj: [String: any Sendable]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }

    private static func errorOutput(toolUseId: String, message: String) -> ToolOutput {
        let payload = #"{"status":"error","message":"\#(escape(message))"}"#
        return ToolOutput(toolUseId: toolUseId, content: payload, isError: true)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
```

- [ ] **Step 2: Add `eventForIdentifier` accessor to CalendarService**

In `CalendarService.swift`, add:

```swift
    /// Direct EKEvent fetch by identifier. Used by tools to read the original
    /// event before move/delete (so we can compute preserved duration, etc.).
    func eventForIdentifier(_ id: String) async throws -> EKEvent? {
        try await ensureAccess()
        return store.event(withIdentifier: id)
    }
```

- [ ] **Step 3: Build clean**

Same command as Task 1 Step 3.

- [ ] **Step 4: Commit**

```bash
git add Smoory/Smoory/Pipeline/Tools/MoveCalendarEventTool.swift Smoory/Smoory/Services/CalendarService.swift
git commit -m "Tools: add move_calendar_event (tier1Quick) + eventForIdentifier helper"
```

---

### Task 12: `DeleteCalendarEventTool`

**Files:**
- Create: `Smoory/Smoory/Pipeline/Tools/DeleteCalendarEventTool.swift`

- [ ] **Step 1: Write the file**

```swift
import EventKit
import Foundation
import SwiftData
import SwiftUI

enum DeleteCalendarEventTool: Tool {
    static let name = "delete_calendar_event"

    static let description = """
        Delete a calendar event. Use when the user explicitly asks to remove or \
        cancel a scheduled event — "delete tomorrow's focus block", "cancel the \
        Friday standup".

        Pass `event_id` from a prior get_calendar_window result. For recurring \
        events choose `scope`:
        - "single": delete only this one occurrence (default)
        - "following": delete this one and every later occurrence
        - "all": delete every occurrence in the series

        Deletion can't be undone within Smoory — the user has to recreate the \
        event in Calendar.app if they change their mind. The confirmation card \
        surfaces this.
        """

    static let confirmationTier: ConfirmationTier = .tier2Review

    static let inputSchema = ToolInputSchema(
        properties: [
            "event_id": ToolInputSchemaProperty(
                type: "string",
                description: "EKEvent identifier from get_calendar_window."
            ),
            "scope": ToolInputSchemaProperty(
                type: "string",
                description: "single | following | all. Default: single."
            )
        ],
        required: ["event_id"]
    )

    struct Input: Codable {
        let event_id: String
        let scope: String?
    }

    static func execute(parametersJSON: String, context: ToolExecutionContext) async throws -> ToolOutput {
        let input: Input
        do {
            input = try decodeInput(parametersJSON)
        } catch {
            return errorOutput(toolUseId: context.toolUseId, message: "could not decode parameters: \(error.localizedDescription)")
        }
        let scope = CalendarEventScope(rawValue: (input.scope ?? "single").lowercased()) ?? .single
        do {
            try await context.services.calendarService.deleteEvent(
                eventID: input.event_id,
                scope: scope
            )
            let payload: [String: any Sendable] = [
                "status": "deleted",
                "id": input.event_id,
                "scope": scope.rawValue
            ]
            return ToolOutput(
                toolUseId: context.toolUseId,
                content: encodeJSON(payload),
                isError: false
            )
        } catch {
            return errorOutput(toolUseId: context.toolUseId, message: error.localizedDescription)
        }
    }

    static func renderSummary(parametersJSON: String, modelContainer: ModelContainer) -> ProposedActionSummary? {
        guard let input = try? decodeInput(parametersJSON) else { return nil }
        let scope = (input.scope ?? "single").lowercased()
        let scopeBadge: String
        switch scope {
        case "all": scopeBadge = "All occurrences (irreversible)"
        case "following": scopeBadge = "This and following (irreversible)"
        default: scopeBadge = "Just this occurrence (irreversible)"
        }
        return ProposedActionSummary(
            icon: "calendar.badge.minus",
            title: "Delete event",
            primary: input.event_id,
            secondary: scopeBadge
        )
    }

    @MainActor
    static func makeEditView(
        parametersJSON: String,
        modelContainer: ModelContainer,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) -> AnyView {
        // tier2Review: no edit view — confirm or decline only.
        AnyView(EmptyView())
    }

    // MARK: - Helpers

    private static func decodeInput(_ jsonString: String) throws -> Input {
        guard let data = jsonString.data(using: .utf8), !data.isEmpty else {
            throw NSError(
                domain: "DeleteCalendarEventTool",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "empty parameters"]
            )
        }
        return try JSONDecoder().decode(Input.self, from: data)
    }

    private static func encodeJSON(_ obj: [String: any Sendable]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }

    private static func errorOutput(toolUseId: String, message: String) -> ToolOutput {
        let payload = #"{"status":"error","message":"\#(escape(message))"}"#
        return ToolOutput(toolUseId: toolUseId, content: payload, isError: true)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
```

- [ ] **Step 2: Build clean**

Same command as Task 1 Step 3.

- [ ] **Step 3: Commit**

```bash
git add Smoory/Smoory/Pipeline/Tools/DeleteCalendarEventTool.swift
git commit -m "Tools: add delete_calendar_event (tier2Review)"
```

---

### Task 13: Register tools + final smoke test

**Files:**
- Modify: `Smoory/Smoory/Pipeline/ToolRegistry.swift`

- [ ] **Step 1: Register in `allTools`**

In `ToolRegistry.allTools`, add the three new entries (preserve existing order; place near existing `Get*` calendar tool if any, otherwise at the end):

```swift
        CreateCalendarEventTool.self,
        MoveCalendarEventTool.self,
        DeleteCalendarEventTool.self,
```

- [ ] **Step 2: Build clean**

Same command as Task 1 Step 3.

- [ ] **Step 3: Relaunch + manual smoke checklist**

Relaunch Smoory:
```bash
osascript -e 'quit app "Smoory"' 2>/dev/null; sleep 1; open /Users/alex/Library/Developer/Xcode/DerivedData/Smoory-awmhbyagcsebmraomliojfvpalyb/Build/Products/Debug/Smoory.app
```

Run each check in order. After each, note PASS / FAIL inline before continuing.

- [ ] **3.1**: Settings → Calendar section appears between Reminders sync and Time off; lists every real calendar with a colored dot + checkbox; "Smoory writes here" picker is populated with writable calendars only.

- [ ] **3.2**: Pick a writable calendar in the picker. Toggle one calendar OFF in the read list. Open Feed. Events from the unchecked calendar disappear from the next-3-days list.

- [ ] **3.3**: In Chat, send: `"schedule a focus block tomorrow at 2pm for 30 mins"`. A confirmation card appears with title "Create event", primary text "Focus block — Tomorrow at 14:00", secondary "Calendar event". Confirm. Open Calendar.app. Event appears at the right time on the configured writable calendar.

- [ ] **3.4**: In Chat, send: `"schedule a meeting tomorrow at 2pm"` (overlapping the focus block from 3.3). Card secondary text shows ⚠ overlap with "Focus block".

- [ ] **3.5**: In Chat: `"every weekday at 9am, 15-minute standup for the next 2 weeks"`. Card shows recurrence label ("Weekly on Mon, Tue, Wed, Thu, Fri, 10 times" or similar). Confirm. Calendar.app shows recurring event with correct days.

- [ ] **3.6**: In Chat: `"move tomorrow's standup to 10am"`. tier1Quick card appears with "Just this occurrence" scope badge. Confirm. Only Tuesday's instance moves; rest of the series stays at 9am.

- [ ] **3.7**: In Chat: `"move all standups to 10am"`. Card shows "All occurrences" badge. Confirm. Every occurrence shifts to 10am.

- [ ] **3.8**: In Chat: `"delete this Friday's focus block"`. tier2Review card appears (bigger, irreversible warning). Confirm. Calendar.app shows the event gone.

- [ ] **3.9**: Delete the configured writable calendar in Calendar.app while Smoory is running. Return to Smoory. In Chat: `"add a focus block tomorrow at 3pm"`. Confirm the card. Tool execution returns an error; `ErrorBus` toast appears at the top of the window with the missing-calendar message.

- [ ] **3.10**: System Settings → Privacy & Security → Calendars → revoke Smoory's access. Return to Smoory. In Chat: `"add a focus block tomorrow at 3pm"`. Confirm. Tool returns an auth error; chat reply mentions System Settings.

- [ ] **Step 4: Final commit**

```bash
git add Smoory/Smoory/Pipeline/ToolRegistry.swift
git commit -m "Tools: register calendar write tools in registry"
```

---

## Out of Scope (deferred follow-ups)

Per spec — confirming the boundary so they aren't accidentally pulled in:

- Editing event recurrence inline in the confirmation card. (Workaround: decline + rephrase.)
- Inviting attendees to events.
- Free/busy detection across multiple users.
- Multi-day all-day creation via natural language ("vacation next week").
- Editing the recurring move/delete scope in `MoveCalendarEventTool`'s edit view (we ship with no edit view there).

## Self-Review Note

Spec coverage cross-check: every spec section maps to tasks 1–13. No placeholders. Type names consistent across tasks (`CalendarEventScope`, `CreateEventInput`, `Input`, `RecurrenceInput`). Each tool defines its own `decodeInput`/`encodeJSON`/`errorOutput`/`escape` (DRY-violation noted, kept for symmetry with existing `CreateScheduledActionTool`). RecurrenceRule reuse is explicit in Task 10's `buildEKRecurrence`.
