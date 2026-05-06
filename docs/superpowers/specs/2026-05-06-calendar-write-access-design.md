# Calendar write access — design

**Status:** Draft, ready for plan.
**Phase:** Calendar functionality (extends existing read-only `CalendarService`).
**Author:** Brainstorm session 2026-05-06.

## Goal

Let Smoory create, move, and delete calendar events from chat — and let the user pick which calendars Smoory reads from, which one it writes to. Reuse the existing `EKEventStore` plumbing and the RFC 5545 RRULE round-trip already shipped on the Reminders sync side.

## Design decisions (locked)

| # | Decision | Choice |
|---|---|---|
| 1 | Where do new events get written? | Settings-configured "Smoory writes here" calendar. Falls back to system default if unset. |
| 2 | Which write tools? | Three: `create_calendar_event`, `move_calendar_event`, `delete_calendar_event`. |
| 3 | Confirmation tier per tool | Graduated by risk: create + move = `tier1Quick`. delete = `tier2Review`. |
| 4 | Per-calendar read filter shape | Opt-out — every calendar included by default; user unchecks the noisy ones. |
| 5 | Recurrence shape | Single tool with optional `recurrence` parameter (mirrors `create_scheduled_action`). |
| 6 | Scope on move/delete of recurring events | LLM passes a `scope: "single" \| "following" \| "all"` parameter; confirmation card surfaces the chosen scope. |
| 7 | Conflict detection | Tool-side scan via `EKEventStore.predicateForEvents`. Surfaces overlaps in the confirmation card's secondary text. Never blocks. |

## Components

```
Smoory/Services/CalendarService.swift                 (extend)
  + createEvent(input:) -> EKEvent
  + moveEvent(eventID:scope:newStart:newEnd:) -> EKEvent
  + deleteEvent(eventID:scope:)
  + findConflicts(start:end:excludingEventID:) -> [CalendarEvent]
  + listAvailableCalendars() -> [EKCalendar]
  + writableCalendar() -> EKCalendar?    // resolves Settings → EKCalendar; falls back to default
  - eventsForCurrentWindow(now:)         // applies excludedCalendarIDs filter

Smoory/Pipeline/Tools/CreateCalendarEventTool.swift   (new, tier1Quick)
Smoory/Pipeline/Tools/MoveCalendarEventTool.swift     (new, tier1Quick)
Smoory/Pipeline/Tools/DeleteCalendarEventTool.swift   (new, tier2Review)

Smoory/Surfaces/Settings/CalendarSettingsSection.swift   (new)
Smoory/Surfaces/Settings/CalendarSettingsViewModel.swift (new, @Observable @MainActor)

Smoory/Pipeline/ToolRegistry.swift                    (extend allTools)
```

**Reused without modification:**
- `Pipeline/Reminders/RecurrenceRule.swift` — RFC 5545 round-trip (`toEKRecurrenceRule`, parsing).
- `Pipeline/Tools/ScheduledActionTimeResolver` — natural-language time parsing.
- `Surfaces/Common/ErrorBus.swift` — write failures surface as toasts.

## Tool shapes

### `create_calendar_event` (tier1Quick)

```
Input {
    title: String                           // required
    start: String                           // ISO 8601 preferred; natural-lang accepted
    end: String?                            // exactly one of `end` or `duration_minutes`
    duration_minutes: Int?
    location: String?
    notes: String?
    is_all_day: Bool = false
    recurrence: Recurrence?                 // optional
}
Recurrence {
    frequency: "daily" | "weekly" | "monthly" | "yearly"
    interval: Int = 1
    days_of_week: [String]?                 // for weekly: "MO","TU"...
    end: { count: Int } | { until: ISO8601 } | null
}
```

`execute()`:
1. Resolve `start` / `end` via `ScheduledActionTimeResolver` (fall through to ISO parsing).
2. Compute conflicts via `CalendarService.findConflicts`.
3. Build `EKEvent` on `writableCalendar()`. Convert `Recurrence` → `EKRecurrenceRule` via `RecurrenceRule`.
4. `store.save(event, span: .thisEvent, commit: true)`.
5. Return `{status:"created", id, calendar_name, conflicts}`. The LLM uses `conflicts` to acknowledge overlaps in chat.

`renderSummary`: title • formatted time range • secondary = calendar name + ⚠ count if conflicts.

`makeEditView`: minimal SwiftUI form for title / start / end / location / recurrence.

### `move_calendar_event` (tier1Quick)

```
Input {
    event_id: String                        // EKEvent.eventIdentifier
    new_start: String
    new_end: String?                        // optional; preserve original duration if omitted
    scope: "single" | "following" | "all" = "single"
}
```

`execute()`:
1. Look up `EKEvent` by `event_id`.
2. Resolve `new_start` / `new_end`. If `new_end` omitted, preserve `event.endDate - event.startDate`.
3. Resolve target event for the chosen scope:
   - `"single"` → operate on the EKEvent directly with `EKSpan.thisEvent`.
   - `"following"` → operate on the EKEvent directly with `EKSpan.futureEvents`.
   - `"all"` → walk back to the first occurrence in the recurrence series, operate on it with `EKSpan.futureEvents` (EventKit has no "all events" span; this is the canonical EventKit pattern for "edit the whole series").
4. Mutate `startDate` / `endDate` on the resolved target event.
5. `store.save(target, span: …, commit: true)`.
6. Return `{status:"moved", id, new_start, new_end, scope}`.

`renderSummary`: "Move 'X' from … to …" • secondary = scope badge.

### `delete_calendar_event` (tier2Review)

```
Input {
    event_id: String
    scope: "single" | "following" | "all" = "single"
}
```

`execute()`:
1. Look up `EKEvent`.
2. Resolve target + span using the same rule as `move_calendar_event`:
   - `"single"` → this event, `EKSpan.thisEvent`.
   - `"following"` → this event, `EKSpan.futureEvents`.
   - `"all"` → walk back to the first occurrence, `EKSpan.futureEvents`.
3. `store.remove(target, span: …, commit: true)`.
4. Return `{status:"deleted", id, scope}`.

`renderSummary`: title • formatted time + scope badge + "this can't be undone".

No `makeEditView` (nothing to edit on a delete).

## Settings UI

New `Calendar` section in `SettingsView`, between "Reminders sync" and "Time off":

- **Authorization status** row (existing pattern from Reminders sync).
- **"Smoory writes here"** picker — populated from `listAvailableCalendars()` filtered to writable calendars (no subscribed/read-only). Defaults to system default.
- **"Read from these calendars"** list of toggles, one per available calendar, default-on. Shows event counts as a hint.

Storage:
- `@AppStorage("calendar.writableCalendarID")` — `String?`, holds `EKCalendar.calendarIdentifier`. Empty/nil → use system default.
- `@AppStorage("calendar.excludedCalendarIDs")` — `Data`, JSON-encoded `[String]` of excluded calendar identifiers.

`CalendarSettingsViewModel` (`@Observable @MainActor`) — eagerly initialized via `_vm = State(wrappedValue:)` (matches the F-17 fix pattern). Subscribes to `EKEventStoreChanged` notifications so the calendar list refreshes when the user creates/deletes calendars in Calendar.app.

Read-filter integration: `CalendarService.eventsForCurrentWindow` reads excluded IDs at call time and pre-filters the EKCalendars passed to `predicateForEvents`. No perf cost.

## Data flow

Chat tool calls follow the same shape as `create_scheduled_action`:

1. LLM emits tool call.
2. `Orchestrator` routes to `ChatViewModel` (non-silent tier).
3. `ChatViewModel` renders a `ProposedActionSummary` card. Conflict scan happens at render time.
4. User confirms / edits (tier1Quick only) / declines.
5. On confirm, `Tool.performAction()` runs the EKEvent save.
6. Tool returns to LLM. `WidgetCenter.reloadAllTimelines()` fires after success.

EKEvent state lives in EventKit; Smoory never persists copies. The Feed widget refresh is the only side-write.

## Error handling

| Failure | Where caught | User-visible result |
|---|---|---|
| Calendar permission not `.fullAccess` | `CalendarService.ensureAccess()` | Tool returns isError; chat surfaces "Grant access in System Settings". |
| Configured writable calendar deleted | `writableCalendar()` returns nil | `errorBus.report("Smoory's writable calendar isn't available — pick another in Settings.")` + tool returns isError. |
| `.writeOnly` Sequoia tier | Existing `CalendarServiceError.writeOnlyAccess` | Reuse Reminders-sync alert pattern with System Settings deep-link. |
| EKEvent.save fails | Tool catch | Tool returns isError with EK error message; `errorBus` surfaces. |
| Time resolution fails | `TimeResolverError` | Tool returns isError; LLM rephrases. |
| Conflict | Not an error | Surfaced in confirmation card secondary text only. |

State consistency: EKEvent saves are atomic per call. Read tool `get_calendar_window` honors the excluded-calendars filter, so the LLM never proposes moving a hidden event.

`findConflicts` honors the excluded-calendars filter for the same reason — if the user has muted "Birthdays", a 2pm birthday event should not surface as a ⚠ overlap when scheduling a 2pm focus block. The user explicitly said "ignore this calendar"; we ignore it everywhere.

## Testing

Manual smoke checklist after implementation:

1. Calendar section appears in Settings; available calendars listed with event counts.
2. Pick writable calendar; uncheck one read-calendar; Feed window drops those events.
3. Chat: "schedule a focus block tomorrow at 2pm for 30 mins" → confirmation → confirm → Calendar.app shows event.
4. Chat: "schedule a meeting tomorrow at 2pm" (overlap) → confirmation card secondary shows ⚠ overlap text.
5. Chat: "every weekday at 9am, 15-minute standup for the next month" → confirmation → confirm → recurring event in Calendar.app.
6. Chat: "move tomorrow's standup to 10am" → tier1Quick card with "single occurrence" scope badge → confirm → only Tuesday moves.
7. Chat: "move all standups to 10am" → tier1Quick card with "all N occurrences" scope badge → confirm.
8. Chat: "delete this Friday's focus block" → tier2Review card with irreversible warning → confirm.
9. Delete the configured writable calendar in Calendar.app; attempt a create → ErrorBus toast surfaces the missing calendar.
10. Revoke calendar permission in System Settings; attempt a create → tool returns auth error; chat surfaces it.

Build gate: `xcodebuild … build` clean before each commit. No XCTest fakes against EKEventStore — cost outweighs value for personal-app scope.

## Out of scope

- Drafting/sending event invites to attendees (Phase later).
- Per-calendar **write** routing (LLM picks calendar based on event content). The "Smoory writes here" single-target model is locked for v1.
- Free/busy detection across attendees.
- Multi-day all-day event creation via natural language ("vacation next week"). Single-day create works; multi-day deferred.
- Calendar event invites / RSVPs.
- Editing event attendees.

## CLAUDE.md compliance

- New SwiftData entities: none. EventKit owns event state.
- No new dependencies. EventKit is already linked.
- macOS 14+ APIs only.
- Each tool is a small, single-purpose unit (mirrors existing tool registry style).
