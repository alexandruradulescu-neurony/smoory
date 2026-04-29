# Smoory

A personal AI assistant that helps you manage your work, your business, your freelancing, and your life. macOS-native, single-user, runs on your laptop. Smoory orchestrates the tools you already use (Mail, Calendar, Reminders, Contacts) and adds a layer of judgment, memory, and proactive help on top.

This is a personal app for one user. It is not a consumer product, not a SaaS, not multi-tenant. It runs on your machine, stores your data on your machine, talks to one AI provider, and makes your life easier.

---

## What Smoory does

- Reads your email, your calendar, your reminders, and your todos, and connects the dots across them.
- Holds your goals in mind, and quietly checks whether your daily activity is moving you toward them.
- Has a real long-term memory (called **hema**) that lets it remember what you and it talked about weeks or months ago.
- Surfaces the right thing at the right time through a **feed**, a **chat**, and a **desktop widget**.
- Proposes actions — adding todos, drafting replies, rescheduling things, archiving threads — and acts only after you confirm.
- Helps you reflect: 3-minute morning briefs, 3-minute end-of-day reviews, weekly check-ins on goals.
- Learns about the people you correspond with — silently, slowly, transparently.

It does **not** replace your tools. Calendar still runs your calendar. Mail still runs your email. Smoory is the layer on top that knows your goals.

---

## Core principles

These are the rules every design decision is judged against.

**1. Smoory proposes, you confirm, Smoory acts.**
Nothing leaves Smoory's surface without an explicit go-ahead. Confirmation scales with stakes — one tap for adding a todo, full review for sending an email, explicit dialog for ambiguous calls. Memory writes are the one exception: silent, but fully inspectable and editable.

**2. Memory is silent but radically transparent.**
Smoory accumulates facts about you, the people you know, your patterns. Every memory write is visible in a memory inspection view, every fact is editable, every fact has provenance ("why do you think this?"). The trust mechanism is transparency, not gating.

**3. Conversation is the input mechanism, not forms.**
You don't fill out fields. You talk to Smoory and Smoory restructures itself based on what it heard. A structuring layer runs underneath every chat turn, extracting candidate goals, todos, facts, projects, people — surfacing them as proposals you confirm later.

**4. Existing tools stay sources of truth.**
Apple Contacts holds identity. Apple Calendar holds events. Apple Mail holds email. Smoory references and enriches; it doesn't duplicate. Only structured data that has no other home (todos, goals, projects, threads, hema memory, tone profiles) lives in Smoory's database.

**5. AI-first, not rule-first.**
Triage, classification, prioritization, and reasoning are all done by Claude. Rules are brittle; LLMs are not. The cost is a small per-turn API spend — at personal scale this is negligible (a few dollars a month).

**6. Single-user, on-device, private.**
The app runs on your Mac. Your data stays on your Mac. Only the minimum context needed for a given AI call is sent to Anthropic's API. Per-person notes, tone profiles, and sensitive memory fragments are filtered out unless directly relevant to the current task.

**7. Honest scope.**
Cut features rather than half-build them. A Smoory that does five things solidly will get used every day. A Smoory that does fifteen things half-well will be abandoned in a month.

---

## How to use this spec

Read the documents in this order:

1. **README.md** (you're here) — high-level orientation.
2. **ARCHITECTURE.md** — the system as a whole. The loop. The surfaces. The trust model.
3. **RUNTIME.md** — how the AI brain communicates with your machine, what data leaves your Mac, and provider portability.
4. **DATA_MODEL.md** — every entity Smoory stores, with fields and relationships.
5. **MEMORY.md** — the hema specification. Compact memory, vector memory, semantic facts.
6. **BEHAVIORS.md** — what Smoory actually *does*. Onboarding, morning brief, reviews, goal nudges, the email pipeline, threads, tone profiles.
7. **AI_PROMPTS.md** — system prompt drafts for each kind of Claude call.
8. **TOOLS.md** — schemas for tools Claude can call.
9. **DECISIONS.md** — log of architectural choices, the reasoning behind each, and open questions still to resolve.

When working with Claude Code, hand it the relevant document(s) for the phase you're building. Don't dump the whole spec at once.

---

## Build phases

This is the planned order of work. Each phase produces a usable Smoory — you don't get value only at the end.

### Phase 1 — Foundation (no AI yet)
SwiftData models for the full data hierarchy. macOS app shell with sidebar + main area. Calendar read access via EventKit. Apple Contacts integration scaffolded. Basic chat UI that calls the Anthropic API directly with no memory or tools yet. App runs end-to-end as a structured organizer.

**Done when:** you can open the app, manage todos and goals, see your calendar, type messages to a generic Claude.

### Phase 2 — Smoory starts thinking
Tool-calling wired into chat — Claude can read and write all your structured data. Hema implemented in Swift with sqlite-vec. Memory inspection view. Structuring layer that runs after every chat turn and produces candidate writes. The feed surface, basic version. Confirmation flows for tier-1 (quick) and tier-2 (review) actions. Onboarding conversation flow.

**Done when:** you've onboarded Smoory, had a real conversation that produced structured outputs, and memory accumulates between sessions.

### Phase 3 — Daily presence
Morning brief generation (scheduled). Widget that renders the brief. Day review and week review flows. Reflective check-ins per goal. Pattern observation in week reviews. Goal nudges with rate limits.

**Done when:** Smoory greets you in the morning, closes out your day, and the widget is on your desktop.

### Phase 4 — Email
Apple Mail integration: Mail Rule trigger, AppleScript for send, local Mail database read for fast access. Triage classifier with the full taxonomy. Operational alert fast path. Thread inference. Per-contact tone profiles begin learning silently. Drafting flow with tier-2 review-and-confirm.

**Done when:** Smoory reads your mail, surfaces what matters, drafts replies on demand, manages threads.

### Beyond phase 4
- Capture from beyond email and chat (PDF drop, article save, voice memos)
- Cross-everything search
- Calendar writing (propose blocks, schedule sessions, defer meetings)
- Money/finance layer
- End-of-day shutdown ritual
- Postgres migration if hema outgrows sqlite
- iPhone client
- iCloud sync
- Apple Reminders sync
- Habits as a dedicated tracked module

These are explicitly **out of scope for v1**. Don't build them yet.

---

## Tech stack

- **Language & UI:** Swift, SwiftUI, WidgetKit, AppIntents
- **Minimum OS:** macOS 14 (Sonoma) — required for desktop widgets and SwiftData
- **Persistence:** SwiftData for structured state (todos, goals, projects, threads, people, profile, infrastructure, capture)
- **Memory store (hema):** SQLite with `sqlite-vec` extension for vector similarity, plus structured tables for compact memory and semantic facts
- **Embeddings:** Apple's `NLEmbedding` (on-device, free, 300-dim). Swappable for higher-quality embeddings later if needed.
- **AI provider:** Anthropic API. Default model `claude-sonnet-4-6` for chat and most reasoning. `claude-opus-4-7` reserved for the heaviest tasks (week-review pattern observation, complex draft generation). `claude-haiku-4-5` for cheap classification calls (triage).
- **Calendar:** EventKit (`NSCalendarsFullAccessUsageDescription` in Info.plist)
- **Contacts:** Contacts framework (`NSContactsUsageDescription` in Info.plist)
- **Email:** AppleScript (via `osascript` or `NSAppleScript`) for send and rules-triggered access; direct read of `~/Library/Mail/V*/...` `.emlx` files for fast access
- **Mail Rules:** user installs one rule that runs an AppleScript hook on every incoming message, which pokes Smoory via a local socket or file watcher
- **API key storage:** Keychain via `Security` framework
- **Postgres:** scaffolded but not used in v1 (sqlite-vec is sufficient)

---

## Folder structure for the Xcode project

A suggested layout — Claude Code can adjust as it sees fit:

```
Smoory/
├── App/                    # SwiftUI app entry, main shell, navigation
├── Models/                 # SwiftData @Model definitions, enums, DTOs
├── Memory/                 # Hema implementation: compact, vector, facts
├── Services/               # AI client, calendar, contacts, mail, keychain
├── Pipeline/               # The loop: triage, enrichment, structuring, surface
├── Surfaces/
│   ├── Feed/               # Feed view + feed item types
│   ├── Chat/               # Chat view + message rendering
│   ├── Memory/             # Memory inspection view
│   └── Onboarding/         # First-time conversation flow
├── Widget/                 # Widget extension target
└── Resources/              # Assets, localization, prompt templates
```

Bundle identifiers (you set these):
- App: `com.yourname.smoory`
- Widget: `com.yourname.smoory.widget`
- App Group: `group.com.yourname.smoory.shared` (for app↔widget data sharing)

---

## What's next

Read **ARCHITECTURE.md** next.
