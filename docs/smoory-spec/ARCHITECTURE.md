# Architecture

This document describes how Smoory is built as a system. It covers the components, how they relate, the central loop that drives every interaction, the surfaces the user sees, and the trust model that governs all actions.

## The components

Smoory is composed of seven layers. Each layer has a single responsibility, and they communicate through well-defined contracts.

```
┌─────────────────────────────────────────────────────────────────┐
│                         SURFACES                                │
│   Feed   │   Chat   │   Widget   │   Notifications              │
└────────────────────────┬────────────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────────────┐
│                       ORCHESTRATOR                              │
│   The loop: sensor → triage → enrichment → propose → act       │
└────────────────────────┬────────────────────────────────────────┘
                         │
        ┌────────────────┼────────────────┐
        │                │                │
┌───────▼──────┐  ┌──────▼──────┐  ┌─────▼─────────┐
│   AI BRAIN   │  │    HEMA     │  │   TOOLS       │
│ Anthropic    │  │  Memory     │  │  (sensors +   │
│ Claude       │  │   layer     │  │   actions)    │
└──────────────┘  └─────────────┘  └───────┬───────┘
                                           │
                              ┌────────────┼────────────┐
                              │            │            │
                        ┌─────▼────┐ ┌────▼─────┐ ┌────▼─────┐
                        │ SwiftData│ │EventKit  │ │ Apple    │
                        │ (state)  │ │(calendar)│ │ Mail     │
                        └──────────┘ └──────────┘ └──────────┘
```

### 1. Surfaces
The user-facing layer. Five surfaces, each with a distinct role:
- **Feed** — Smoory's home base. A priority-ordered queue of feed items: annotations, suggestions, alerts, briefs, reviews. The action surface.
- **Chat** — a continuous conversational thread with Smoory. Backed by hema for memory across sessions. Reachable from any feed item ("ask about this") and from a global hotkey or menu bar.
- **Widget** — a desktop widget that renders the daily focus card produced by the morning brief. Read-only; does not accept input.
- **Notifications** — used sparingly. Operational alerts and explicit user-asked nudges only. Default behavior is to land in the feed without a system notification.

### 2. Orchestrator
The loop. Every interaction with Smoory — explicit or system-triggered — goes through the same five stages: sensor wakes Smoory, triage classifies, enrichment builds context, surface decides where it lands, action fires after confirmation. Detailed in the next section.

### 3. AI Brain
Anthropic's Claude API. Three models in use:
- `claude-haiku-4-5` for triage and structuring layer (cheap, fast, classification-heavy)
- `claude-sonnet-4-6` for chat, drafting, and most enrichment (default)
- `claude-opus-4-7` for week-review pattern observation and other heavy reasoning (reserved)

Tool-calling is enabled on every chat-and-action call. The orchestrator passes the relevant tools per call type.

### 4. Hema
Long-term memory layer. Three components:
- **Compact memory:** rolling summaries — daily, weekly, and a rolling overall summary, regenerated on cadence.
- **Vector memory:** every conversational turn and every semantic fact embedded into a vector and indexed in sqlite-vec for similarity search.
- **Semantic facts:** discrete records the assistant has learned, structured (text + tags + provenance + timestamp), independently retrievable as both vectors and as queries over structured fields.

Detailed in `MEMORY.md`.

### 5. Tools
Two kinds:
- **Sensor tools** wake the orchestrator (Mail Rule hook, calendar event watcher, scheduled triggers, user input).
- **Action tools** are functions Claude can call to do things — create todo, draft email, archive item, write memory fact, etc. Each tool has a defined confirmation tier.

Tool schemas are in `TOOLS.md`.

### 6. Structured state
SwiftData. Holds every entity Smoory persists outside of memory: roles, goals, projects, threads, todos, habits, people, profile, infrastructure, capture items, feed items.

Schema in `DATA_MODEL.md`.

### 7. External integrations
Read-and-write into Apple's frameworks: EventKit for Calendar, Contacts framework for Apple Contacts, AppleScript and direct file reads for Apple Mail. These are the source of truth for their respective domains; Smoory reads them, references them, and (with confirmation) writes back.

---

## The loop

Every interaction with Smoory follows the same five-stage loop. This is the heart of the system.

```
   ┌─────────┐    ┌────────┐    ┌────────────┐    ┌─────────┐    ┌──────┐
   │ SENSOR  │───▶│ TRIAGE │───▶│ ENRICHMENT │───▶│ SURFACE │───▶│ACTION│
   └─────────┘    └────────┘    └────────────┘    └─────────┘    └──┬───┘
                                                                    │
                                                            ┌───────▼────────┐
                                                            │  MEMORY WRITE  │
                                                            └────────────────┘
```

### Stage 1: Sensor
Something happens that wakes Smoory. Sensors are the only thing that can start a loop. The full list of sensors:

- **Email arrived** (Mail Rule fires AppleScript, AppleScript pokes Smoory)
- **Calendar event added or moved** (polling or push from EventKit)
- **User sent a chat message**
- **Scheduled trigger fired** (morning brief at user's chosen time, day review at evening, week review on Sunday, goal-nudge cadence)
- **User dropped a file on the app or used a share extension**
- **User used a quick-add hotkey or voice input**
- **A previous loop's deferred action came due** (e.g. "remind me about this tomorrow")

Each sensor produces a typed event with a payload. The orchestrator routes by event type.

### Stage 2: Triage
Decide whether to process this signal at all, and if so, how. Triage is a cheap Claude call (Haiku) that classifies the input. The output is one of a small set of categories — they vary by sensor, but always include "drop" as an option.

For email specifically, the triage taxonomy is:
- `noise` — newsletters, promos, social digests → drop, no trace
- `receipt` — transactional confirmations, invoices, shipping → silent log, searchable, no feed item
- `calendar_invite` → route to calendar pipeline
- `alert_action` — operational alert requiring action (server bill, expiring cert, payment failure) → fast-path to top of feed
- `alert_info` — informational system message, no action needed → low-priority feed item
- `correspondence` — real human message → enrichment pipeline

For chat input, triage is simpler — every user message goes to enrichment by default, but a parallel structuring-layer pass extracts candidate writes.

For ambiguous cases, **default to processing rather than dropping.** It's better to over-surface than miss something that mattered. Smoory can later surface ambiguous calls for user feedback ("I almost dropped this as noise — should I have?") and refine over time.

### Stage 3: Enrichment
The expensive call. Build context, run Claude (Sonnet by default), get a structured response. Context assembly is where most of Smoory's intelligence lives, and it varies per event type, but the standard ingredients are:

- The triggering event payload (the email body, the user message, the calendar change)
- Hema retrieval — vector search over conversational memory and semantic facts, filtered by relevance to the event
- Profile blob — your hand-written context about yourself
- Relevant structured state — open todos, today's calendar, the matching thread if any, the matching person if identifiable, the matching infrastructure record if any
- Active goals (if relevant to the event)

Enrichment produces a structured response: an annotation, a suggested action set, a draft, or a reply. The response is what goes to the surface stage.

### Stage 4: Surface
Decide where the enrichment output appears. Options:

- **Feed item** (the default for most things)
- **Notification + feed item** (for operational alerts that need immediate attention)
- **Chat reply** (when the trigger was a user chat message)
- **Widget content** (the morning brief writes to widget cache)
- **Silent memory write** (when the only outcome is updating hema with a learned fact, no user surface needed)

Some events produce multiple surface outputs — an email annotation might land in the feed AND silently write a memory fact AND trigger a candidate todo in the structuring queue.

### Stage 5: Action
The user confirms (or doesn't), and Smoory acts. Actions go through a tiered confirmation system (next section). After action execution, a memory write closes the loop — what was done, when, what the outcome was. This trace becomes part of hema and informs future loops.

---

## Surfaces in detail

### The feed

Smoory's home base. The action surface. Where Smoory speaks to the user.

**Layout:**
- Top item is fully expanded with Jarvis-style reasoning paragraph.
- Items below are collapsed to single-line headlines, tappable to expand.
- Each item has a type badge (📧 email, ✅ todo, 📅 calendar, 🌅 brief, 📝 review, 🔔 alert, 💭 memory candidate, 🎯 goal candidate).

**Ordering:**
Priority-ordered with time as a signal, not the axis. Priority is computed per item from a weighted sum of: explicit alert flag, due-date proximity, source importance (operational alerts > correspondence > captured items), age, role weight, and learned signals from the user's past behavior with similar items.

**Learning:**
The priority weights adjust over time, but **interpretably**. When Smoory observes a pattern (you always dismiss TechCrunch digests, you always act on emails from `boss@`), it surfaces the pattern as a proposed rule:
> "I've noticed you dismiss every TechCrunch newsletter. Want me to auto-archive these going forward?"
The user approves, edits, or rejects. The rule becomes a visible artifact in the app's settings, not a black-box weight shift.

**Item lifecycle:**
- Active: visible in feed, awaits action
- Acted-upon: archived to history, searchable but not visible
- Dismissed: archived to history with dismissed flag (informs future priority)
- Pinned: stays at top regardless of priority (operational alerts pin until resolved)

**Empty state:**
When Smoory has nothing to surface, the feed shows a prompt — "Want to plan tomorrow?" or similar — that initiates a useful conversation. Empty state is opportunity, not failure.

### The Todos surface

A list view of all open todos with editing, search, and subtask support. The one explicit deviation from spec principle 3 ("conversation is the input mechanism, not forms").

**Layout:**
- Search field at the top (matches against todo titles).
- List grouped by due-date status: overdue → today → soon (next 7 days) → later → no due date. Within each group, sorted by priority then chronologically.
- Each row: checkbox (taps complete it), title, due-date pill, priority indicator, role badge, fractional progress (e.g., "3/5") for parent todos with subtasks.
- Tap a row → expands to detail view with full editing (title, notes, due date, priority, role, project, subtasks).
- Swipe a row → quick actions (defer, complete, delete).
- Quick-add row at the top — title + optional date for fast entry.

**Coexistence with chat:**
- Both surfaces write to the same SwiftData store and produce the same hema turn entries. Neither path is "more real."
- Chat path is the canonical channel for ambient capture: *"add a todo to call the dentist tomorrow"* fits a conversational moment.
- Todos surface is for focused work: review, edit, reorganize, bulk operations.
- Tools (`create_todo`, `update_todo`, `complete_todo`, `defer_todo`, `delete_todo`, `create_subtask`) drive both paths — chat uses them via tier-1 confirmation cards; the surface uses them directly when the user has already taken explicit action.

**Subtasks:**
- One level of nesting (todo → subtask). Subtasks cannot have subtasks.
- Subtasks are full Todos with `parentTodo` set, displayed inline under the parent in the list view.
- Parent shows fractional progress (`3/5`) when it has subtasks; parent is NOT auto-completed when all subtasks are done.

### The chat

A continuous conversational thread with Smoory. One thread per user — no topic-based threading. Hema handles cross-session memory.

**Reachability:**
- Main chat view in the app
- Global hotkey (configurable, default `⌘⇧Space`) opens chat from anywhere
- Menu bar icon shows chat in a popover
- Tap on any feed item → "ask about this" → opens chat with that item pre-loaded as context

**Message types:**
- User text input
- User voice input (transcribed via macOS dictation, then sent as text)
- File drop into chat (PDFs, images, text files become Capture items, also referenced in the message)
- Smoory text replies (markdown rendered, may contain inline action proposals)

**Inline action proposals:**
When Smoory replies and the response includes a proposed action, it appears as a tappable card inside the chat message. The card respects the same confirmation tier system as the feed.

### The widget

A medium-sized desktop widget (also small and large variants) that renders the **daily focus card** generated by the morning brief.

**Content:**
- One headline: today's primary focus (e.g. "Ship the Apollo spec")
- 2–3 secondary items
- Calendar at-a-glance (next event)
- Quick stats if relevant (e.g. goal streaks)

**Refresh:**
Widget content is cached as a JSON file in the App Group container. The main app writes to this file whenever the morning brief is generated, when the user marks something done, or when significant state changes. The widget reads the JSON on its timeline refresh (every 15–30 minutes per system schedule, plus immediate refresh via `WidgetCenter.shared.reloadAllTimelines()` from the app).

**No interaction:**
The widget does not accept input. Tapping it opens the main app. This keeps widget logic simple and avoids the constraints widgets place on interaction.

### Notifications

Used sparingly. Smoory does not notify by default; items land in the feed silently.

**When notifications fire:**
- Operational alerts (action required, time-sensitive)
- Scheduled morning brief (configurable: notification on/off)
- User-set reminders ("remind me about X tomorrow at 9am")
- Day-review prompt at end of day (configurable)

**When notifications never fire:**
- Email arrival
- Routine feed items
- Memory candidates
- Most goal nudges (those go in morning brief)

---

## Trust model and confirmation tiers

Every action Smoory can take falls into one of three confirmation tiers. The triage and enrichment stages select the tier when generating the action proposal.

### Tier 1 — Quick-confirm (one tap)
Smoory shows a card with the proposed action. User taps once. Done.

Used for low-stakes, easily reversible actions:
- Add a todo
- Mark a todo done
- Set a reminder
- Defer/snooze an item
- Update a tag or metadata field
- Confirm a candidate goal or candidate person record

### Tier 2 — Review-and-confirm
Smoory shows the full proposed artifact (a draft email body, a calendar invite, a contact edit). The user can edit before approving.

Used for actions that involve another human or modify a shared record:
- Send an email (review the draft first)
- Reply to an email
- Create or modify a calendar event
- Update a person record (name, company, tone profile)
- Archive multiple items in batch

### Tier 3 — Explicit dialog
Smoory writes nothing. Instead, opens a chat dialogue: "Want me to draft a reply?" or "I think these emails belong together as a thread — should I treat them that way?"

Used for high-ambiguity situations where Smoory isn't confident enough to even propose a concrete artifact:
- First-time inferences (thread grouping, person record creation from a single email)
- Sensitive judgments (drafting an apology, declining an offer, setting boundaries)
- Anything where Smoory's confidence is below a configurable threshold

### Memory writes — the special case
Memory writes happen silently — no confirmation dialog interrupts the user. **But** every memory write is fully visible in the memory inspection view, fully editable, fully deletable, and has provenance ("Smoory wrote this fact based on these conversation turns").

This is deliberate. Confirmation for every memory write would be exhausting and would defeat the point of long-term memory. Transparency is the trust mechanism instead.

---

## The structuring layer

The structuring layer is what makes "conversation as the input mechanism" actually work.

After every user chat turn, in parallel with generating the conversational reply, Smoory runs a second Claude call (Haiku, cheap) with a specific prompt: *"What structurable information did the user just convey? Produce a list of candidate writes."*

The output is zero or more candidate records, each with a type (`goal`, `todo`, `project`, `person`, `infrastructure`, `availability`, `tone_observation`, etc.), the proposed content, and a confidence score.

Candidates surface in the feed as low-priority items, batched, not interrupting the chat:
> "You mentioned wanting to read 50 pages a day — make this a goal? [yes / not now / never]"

The user reviews these in batches when convenient. Confirmed candidates become real records. Rejected candidates become negative training signal — Smoory learns not to propose similar things.

**This is the mechanism that lets onboarding be a conversation.** The first 20–30 minute sit-down produces dozens of candidates as the structuring layer runs continuously through the chat. By the end of the conversation, the user has confirmed roles, goals, projects, key people, infrastructure, working hours, and patterns — without filling out a single form.

---

## Apple framework integration map

| Domain | Framework | Permission key | Read | Write |
|---|---|---|---|---|
| Calendar | EventKit | NSCalendarsFullAccessUsageDescription | yes | v2+ |
| Contacts | Contacts | NSContactsUsageDescription | yes | yes |
| Mail | AppleScript + direct file read | (none, but Automation prompt) | yes | yes (via send AppleScript) |
| Reminders | EventKit | NSRemindersFullAccessUsageDescription | yes (4.7) | yes (4.7) |
| Speech / dictation | Speech + AVAudioEngine | NSSpeechRecognitionUsageDescription, NSMicrophoneUsageDescription | yes (4.11) | n/a |
| Notifications | UserNotifications | provisional | n/a | yes |
| Background | BGTaskScheduler | (none) | n/a | n/a |
| Keychain | Security | (none) | yes | yes |

Reminders integration shipped in 4.7 (bidirectional sync, opt-in via Settings). Speech / dictation shipped in 4.11 (review-sheet input bars only). Calendar writing is still v2+.

---

## Performance and cost

**Latency:**
- Triage call (Haiku): ~300–700ms typical
- Enrichment call (Sonnet with tool-calling): 1.5–4s typical
- Structuring layer (Haiku, parallel to chat reply): ~500ms — runs in background, doesn't block the user

**Cost:**
At expected personal usage volume (20–50 chat turns/day, 100–300 emails/day, daily briefs and reviews), Anthropic API spend should land around $5–15/month. Triage handles most email volume cheaply; only ~5–10% of emails reach enrichment.

**Storage:**
Hema vectors at 300-dim float-32 are 1.2KB per turn. 10,000 turns ≈ 12MB of vectors. SQLite handles this trivially. The full database (state + memory) should stay under 1GB for years of normal use.

---

Read **RUNTIME.md** next.
