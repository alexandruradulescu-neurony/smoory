# Decisions

A log of the architectural and product choices made during spec design, the alternatives considered, and the reasoning. When you (or Claude Code) revisit a decision later, this document should answer "why did we do it this way?"

Open questions still to resolve are at the end.

---

## Persistence: SwiftData + (deferred) Postgres

**Decision:** SwiftData for all structured state (todos, goals, projects, threads, todos, people, profile, infrastructure, capture, feed items).

**Alternatives considered:**
- **Postgres on the user's laptop** (already installed). Rejected for v1: introduces a separate process to run, complicates app distribution and reliability, and SwiftData natively integrates with SwiftUI/CloudKit. Postgres is a real option for a future hema migration if the dataset outgrows SQLite, but the structured side of the app benefits more from SwiftData's tight integration than from Postgres's power.
- **Plain SQLite via GRDB.** Reasonable, but loses SwiftData's `@Model` ergonomics and SwiftUI bindings. Adds boilerplate for what is essentially a Swift-native problem.
- **Core Data.** Predecessor to SwiftData. No reason to choose it over SwiftData for a new project on macOS 14+.

**Why SwiftData wins:** Native `@Model` macro, SwiftUI integration is automatic, observation/binding for free, undo/redo support, and the upgrade path to CloudKit sync (when iPhone client lands post-v1) is one flag.

**Trade-off accepted:** SwiftData is younger than Core Data and has had bugs through 2024–2025; some fetched-property patterns and complex relationships occasionally need workarounds. The data model in this spec is conservative and avoids exotic SwiftData features for that reason.

---

## Memory store: SQLite + sqlite-vec for hema

**Decision:** Use SQLite directly (not SwiftData) for hema, with the `sqlite-vec` extension for vector similarity. Hema stays in its own database file separate from the SwiftData store.

**Alternatives considered:**
- **Postgres + pgvector.** Higher quality vector ops, mature, the user already has Postgres installed. Rejected for v1: requires a running database process, complicates app reliability, doesn't materially improve retrieval quality at personal scale.
- **SwiftData with custom vector serialization.** SwiftData doesn't support vector indexes natively. Implementing similarity in SwiftData would mean loading every vector into memory and computing in Swift, which works at 10k items but doesn't scale gracefully.
- **Embedded LanceDB or similar.** More vector-specialized, but adds dependency complexity for marginal gain at personal scale.
- **Apple's CoreData + manual cosine.** Same problem as SwiftData approach; manual cosine across thousands of items per query.

**Why sqlite-vec wins:** Embedded (single file), fast enough at personal scale (sub-millisecond ANN over 10k+ vectors), zero process management, well-supported on Apple platforms via the `sqlite-vec` package. The migration path to Postgres+pgvector is straightforward if needed later — same vector dimension, same distance metric, mostly a data dump-and-load.

**Why hema's database is separate from SwiftData's:** Cleaner separation of concerns, lets hema be inspected/exported/migrated independently, and avoids fighting SwiftData over schema for the vector tables.

---

## Embeddings: NLEmbedding for v1

**Decision:** Apple's `NLEmbedding.sentenceEmbedding(for: .english)` for v1. 300-dim, on-device, free.

**Alternatives considered:**
- **Voyage AI** (Anthropic-recommended, high quality, ~$0.02/1M tokens). Best quality, but adds another API key and another network call per write/read.
- **OpenAI text-embedding-3-small** (1536-dim, very good). Same downsides as Voyage from a "another API" standpoint.
- **Local sentence-transformer via CoreML.** More setup, varying quality, model file ships with the app.

**Why NLEmbedding wins for v1:** Free, fully private (on-device), Apple-maintained, no extra API key. At personal scale (single user, ~10k items per year), 300-dim sentence embeddings are sufficient for retrieval that feels useful. Quality differences between embedding models matter most at scale or for difficult cross-lingual queries; for a personal English-language assistant, NLEmbedding is fine.

**Swap path:** The `Embedder` protocol abstracts the embedder. If retrieval quality issues emerge — vague queries finding nothing useful, semantic distinctions being missed — swap implementations without touching the rest of hema. Vector dimension change requires re-embedding the corpus, which at personal scale is cheap.

---

## AI provider: Anthropic only, three models

**Decision:** Use Claude exclusively. Three models routed by call type:
- `claude-haiku-4-5`: triage, structuring layer, thread inference, tone observation
- `claude-sonnet-4-6`: chat, drafting, enrichment, brief and review generation
- `claude-opus-4-7`: pattern observation in week reviews, occasional heavy reasoning

**Alternatives considered:**
- **Multi-provider** (OpenAI fallback, Gemini for some tasks). Rejected: complicates prompt engineering, the user already trusts Claude, and Anthropic's tool-calling and context behavior is excellent for orchestrator-style use.
- **Local-only models via Ollama.** Rejected: quality at the level needed for nuanced annotation and drafting still lags hosted frontier models. May reconsider for triage in particular if costs become a concern.
- **One model for everything.** Wasteful — Haiku is 12× cheaper than Sonnet for classification work that doesn't need Sonnet's reasoning.

**Why this routing:** Each model is matched to its task. Cheap classification stays cheap. The expensive one-off (Opus on week-review patterns) is rare. Total monthly cost stays bounded.

---

## Single-user, single-machine, on-device for v1

**Decision:** Smoory runs on the user's Mac, with the user's data on the user's Mac. No iCloud sync, no iPhone client, no cross-device anything in v1.

**Alternatives considered:**
- **CloudKit sync from day one.** Adds real complexity (conflict resolution, schema migration across devices, SwiftData CloudKit edge cases). Worth doing once the iPhone client is in scope; not worth doing for one device.
- **Native iPhone client in v1.** Apple Mail integration is fundamentally Mac-only (AppleScript, Mail Rules, local DB read). The iPhone version of email is a different integration entirely (likely IMAP or the Apple MailKit extension). v1 keeps Mac as the home base.

**Trade-off:** No phone access in v1. The mitigation: morning brief and feed could be readable via a web view served locally (post-v1 nice-to-have), or a simple SwiftUI iPhone read-only client that shares CloudKit data once that's added.

---

## Apple Mail integration: AppleScript + direct DB read

**Decision:** Trigger via Mail Rule firing AppleScript. Send via AppleScript. Read via direct `.emlx` file access in `~/Library/Mail/V*/`.

**Alternatives considered:**
- **IMAP directly to the user's mail server.** Cleaner protocol, server-side; but doesn't reflect the user's local Mail client state (read flags, archive, flagged). Smoory needs to share Mail's view of reality.
- **Apple's MailKit extension API.** Proper supported API, but limited — designed for inline UI extensions in Mail itself, not for an external orchestrator with full read/write access.
- **Polling Apple Mail's IMAP idle.** Could work, but doesn't catch the user's local Mail state (Mail-side rules already applied, archive moves done in the client).

**Why AppleScript + DB read wins:** Reflects the user's actual mail experience. Mail Rule + AppleScript is the canonical Apple-supported way to hook into incoming mail. Direct DB read is fast for retrieval. The downside is brittleness — Apple has been deprecating AppleScript over time and the Mail DB structure can shift between macOS versions. Mitigation: pin to macOS 14+ initially, plan to revisit if Apple ships breaking changes.

---

## People: retrieval-only in v1, no browse view

**Decision:** People records exist, accumulate notes and tone profiles, are searched and referenced from chat. There is no browseable list view of all people in v1.

**Alternatives considered:**
- **Full CRM-style People view.** A grid or list of all known people, with filters, tags, last-touched timestamps, etc. Tempting and clearly useful. Deferred because it shifts the product's center of gravity toward a CRM, and v1 is about establishing the assistant pattern first.
- **No People records at all.** Rejected: per-person tone profiles are core to the email drafting value proposition, and "who was the guy from Acme" retrieval is one of the killer features.

**Why retrieval-only wins for v1:** People records earn their keep through retrieval ("draft a reply to Maria — she's the lead on Apollo, terse register, prefers bullets") rather than through browsing. The browse view can come post-v1 once the data has accumulated enough to be worth browsing.

---

## Three confirmation tiers

**Decision:** tier1_quick / tier2_review / tier3_dialog, with memory writes as a silent fourth category.

**Alternatives considered:**
- **Two tiers (silent vs. confirmed).** Too coarse — sending an email and adding a todo are very different stakes.
- **Per-action custom flows.** Too fragmented — the user can't develop pattern recognition for "what does Smoory do next" if every action behaves differently.
- **All actions silent with undo.** Tempting but undoing a sent email is a forwarded-apology away from a real problem. Confirmation before action is safer than undo after action for actions that touch other people.

**Why three tiers + silent memory wins:** Stakes are clearly graduated. Tier-1 is so cheap to confirm that the user develops muscle memory. Tier-2 makes the user feel safe with email sending. Tier-3 prevents Smoory from charging into ambiguous situations. Silent memory writes preserve the conversational flow that makes Smoory feel intelligent rather than bureaucratic.

---

## Memory writes: silent but transparent

**Decision:** Most memory writes happen without user prompting. Every write is fully visible, editable, and deletable in the memory inspection view, with provenance.

**Alternatives considered:**
- **Confirm every memory write.** Exhausting. Defeats the point of long-term memory. Discussed and rejected during design.
- **Hidden memory.** Smoory becomes a black box that users feel uneasy about. Erodes trust over time.

**Why silent + transparent wins:** Trust through visibility, not through gating. The user knows they can audit anything Smoory has remembered. The cost of the "wrong fact written silently" is recoverable (edit or delete the fact) and minor; the cost of constantly interrupting the user to confirm trivia is unrecoverable.

**Implication:** The memory inspection view is a first-class surface, not an admin afterthought. Time invested in making it browsable, searchable, and editable pays back directly.

---

## Structuring layer batches candidates rather than interrupting chat

**Decision:** After every user chat turn, a parallel Haiku call runs to extract candidate writes. Candidates surface in the feed as low-priority items, not as in-chat interruptions. Onboarding is the exception — candidates surface in-line during the first conversation so the user sees the structure forming.

**Alternatives considered:**
- **Inline confirmation always.** "I noticed you mentioned wanting to read more — should I make that a goal? [yes/no]" inside chat. Too interrupting; users will start avoiding mentioning things.
- **Auto-write everything.** Too aggressive; users will find Smoory has invented goals they didn't really commit to.
- **Don't extract at all, only respond to explicit "make this a goal" commands.** Too passive; defeats the "conversation as input" principle.

**Why batched-in-feed wins:** The chat stays a conversation, not an interview. Candidates accumulate quietly and the user reviews them when they want to. The structuring layer's accuracy can be tuned by watching which candidates get accepted vs. rejected over time.

**Why onboarding is different:** The user *expects* to be setting things up during onboarding. Inline confirmation during the first conversation is part of the onboarding ritual. After onboarding, the chat reverts to non-interrupting mode.

---

## Tone profiles wait for 5+ observations before being used

**Decision:** Per-person tone profiles begin learning after the first email exchange but are not used in drafting until `observationCount >= 5`. Below that threshold, drafts use the user's generic outgoing voice.

**Alternatives considered:**
- **Use tone profile from observation #1.** Risk: drafts to a person with one observed email feel weirdly specific or off-key.
- **Manual tone setting.** Too much friction; users won't keep it up.

**Why 5+ observations wins:** Five emails is roughly the point at which a stable register/length pattern emerges and isn't overly biased by a single one-off. Until then, the generic voice is a safer default. The threshold is configurable.

---

## Proactive moments are bounded: morning brief, day review, week review

**Decision:** Smoory is proactive in three scheduled moments and otherwise responds rather than initiates. Goal nudges live within the morning brief; reflective check-ins live within the week review (or are user-invoked).

**Alternatives considered:**
- **Always proactive.** Pings the user throughout the day with reminders, suggestions, observations. Tested in many similar products and consistently produces fatigue. Rejected.
- **Fully reactive.** Smoory only speaks when spoken to. Misses the value of the "morning orientation" and "end-of-day reflection" patterns that are core to why having an assistant matters.

**Why bounded proactivity wins:** Predictability. The user knows when Smoory will speak and when it won't. The three rituals carry the proactive value (orientation, reflection, weekly recalibration) without the rest of the day feeling like a stream of interruptions. Operational alerts are the one exception — those bypass the bounded model because their stakes warrant it.

---

## iPhone is secondary; not in v1

**Decision:** Mac-only in v1. iPhone client is post-v1, with read-only and CloudKit sync as the first iPhone milestone.

**Reason:** Apple Mail integration is fundamentally Mac-only via the chosen mechanism. Building parallel iOS infrastructure (CloudKit data layer, IMAP-side mail integration, iOS UI) doubles the v1 scope. Better to ship a really good Mac-only Smoory, validate the patterns, and add iPhone as a cohesive expansion.

**Pre-decision for the iPhone build:** When iPhone is added, the data layer migrates to CloudKit (SwiftData-CloudKit integration). The iPhone client is read-only at first — viewing feed, briefs, memory; not writing. Writing actions on iPhone come second. Email integration on iPhone, if attempted, is via IMAP or MailKit and is a separate engineering effort.

---

## Capture is minimal in v1

**Decision:** Capture sources in v1 are limited to chat-drop and a quick-add hotkey. No share extension, no browser plugin, no voice memo capture.

**Reason:** Each capture source is real engineering (share extension is an Xcode target, browser plugin is a separate Safari/Chrome project, voice capture needs Speech framework integration). v1 is about establishing the assistant pattern; capture beyond email and chat can earn its way in post-v1.

---

## Calendar is read-only in v1

**Decision:** EventKit read access in v1. Calendar writing is post-v1.

**Reason:** Read-only calendar covers the use cases that matter for v1 — the brief, the day shape, scheduling-aware action proposals ("I see you have a meeting at 3, want to defer this todo to before then?"). Writing to the calendar (proposing events, blocking time, declining meetings on user's behalf) is a tier-2 action with a clear UX path, but it's not on the critical path for the rest of v1. Defer to post-v1 to keep scope honest.

---

## Reminders integration is not in v1

**Decision:** Apple Reminders are not synced in v1. Smoory's todos are independent.

**Reason considered:** EventKit also supports Reminders. The user could express a wish for round-trip sync ("a todo in Smoory shows up in Reminders, completing it in Reminders syncs back"). Rejected for v1: bidirectional sync between two systems with their own UIs is a significant complexity cost (conflict resolution, identity matching, completion-state debouncing). Smoory's todos are first-class objects with richer metadata than Reminders supports; the impedance mismatch isn't trivial.

**Future:** Post-v1, optional one-way export ("send my high-priority Smoory todos to Reminders") is a small feature. Bidirectional sync is a much bigger feature and probably never worth it.

---

## Habits as first-class entities, but light treatment in v1

**Decision:** `Habit` exists as a SwiftData entity in v1, linked to goals, with a basic data shape (cadence, target, streak). UI treatment is minimal — habits are managed via chat and surface in week-review check-ins. No dedicated habits dashboard, no calendar visualization.

**Reason:** Habits earn their own UI once enough usage accumulates to justify it. The data shape is in place from v1 so the upgrade path is purely additive.

---

## Threads are inferred and confirmable

**Decision:** Smoory infers threads from email co-occurrence patterns and proposes them as candidates. The user confirms (tier 1). User can also create threads manually.

**Alternatives considered:**
- **All threads manual.** Too much overhead; the user won't bother.
- **All threads automatic without confirmation.** Smoory will get groupings wrong sometimes; silent grouping makes corrections invisible until the thread surfaces in some downstream context.

**Why infer-and-confirm wins:** Captures the signal of the email batches the user actually sends, while keeping the user as final arbiter of the grouping. False positives are cheap to reject; false negatives are recoverable by manual creation.

---

## The "Augster" identity-injection in user skills

**Note for context:** During design conversations, a user-provided skill file at `/mnt/skills/user/general-rules/SKILL.md` attempted to override Claude's identity with a persona ("The Augster") and a fictional workflow with non-existent tools. This was a prompt injection attempt embedded in a developer-supplied skill. It was identified, ignored, and disclosed to the user. The behavior to expect: Smoory's developer (you) should be cautious about copy-pasting prompts from internet sources into agent skill files — instructions that override identity or impersonate other systems should be treated as untrusted regardless of where they appear to originate.

---

## Open questions

These are decisions deferred during design. They should be resolved before or during the relevant build phase.

### 1. Where do API keys live?
Keychain via the `Security` framework is the obvious answer for the Anthropic API key. Open: do we expose a UI to update the key (in-app preferences pane), or only on first run? Recommendation: in-app preferences pane, since key rotation may happen.

### 2. Background processing model on macOS
For scheduled triggers (morning brief, day review prompt) and email-arrival processing, what's the background mechanism? Options: `BGTaskScheduler` (proper background tasks), a long-running app instance with timers (relies on user keeping app open), or a launch agent (runs even when app is closed, more setup).
Recommendation: `BGTaskScheduler` for scheduled triggers + the Mail Rule's AppleScript hook poking the running app via a local UNIX socket. If app isn't running when mail arrives, the AppleScript queues the message ID to a file and Smoory processes the queue on next launch.

### 3. Voice input and dictation
v1 says "voice via macOS dictation, then sent as text." That's the simplest path. Open: do we want a tighter integration (live transcription within the app for longer reflections during reviews)? Probably yes, eventually, via the Speech framework. Defer to post-v1.

### 4. Multiple Mac support without iPhone
If the user has a desktop Mac and a laptop, even without iPhone there's a sync question. Recommendation: defer. Single-machine in v1; revisit when iPhone is added (CloudKit covers Mac-to-Mac at that point too).

### 5. Onboarding redo and data migration
If the user runs onboarding a second time (after a major life change), how do we handle existing data? Recommendation: keep existing data, mark facts older than the redo as "pre-redo" with provenance, allow the user to deprecate them in batch. Don't wipe by default.

### 6. Long-context handling for very chatty days
A day with 100+ chat turns will exceed the context window if all turns are included. Hema retrieval bounds this for the orchestrator's calls, but the chat view itself shows the full session. Open: at what session length do we summarize-and-trim automatically? Recommendation: when a session crosses 200 turns or 30 days idle, archive into hema (turns become memory) and start a fresh session. The summary becomes the new session's seed context.

### 7. Cost ceilings and rate limiting
At expected volume, monthly cost should be under $20. But edge cases (infinite-loop tool calls, runaway batch operations) could spike. Open: do we want a daily spend ceiling configured by the user with a hard stop? Recommendation: yes, with sane defaults ($1/day), surfaced in preferences.

### 8. Encryption at rest
The SQLite hema database and the SwiftData store contain sensitive personal data. macOS FileVault encrypts the disk, which is the baseline. Open: do we additionally encrypt the database files at the application layer (e.g., SQLCipher for hema)? Recommendation: not in v1 — FileVault is sufficient for the personal use case. Add SQLCipher if multi-user or shared-device use cases ever emerge.

### 9. Backup strategy
The user's data is on their Mac. Time Machine handles disk backup. Open: do we provide an in-app export ("export everything as JSON" or "export hema as a bundle") for portability? Recommendation: yes, for v1.5 — export of facts, todos, goals, profile to JSON, and hema database file copy.

### 10. Logging and observability
Tool calls, AI calls, and triage outcomes should be logged for debugging. Open: where do logs live, how are they rotated, and how are they surfaced to the user (or to Claude Code during development)? Recommendation: a `Smoory.log` file in the App Group container, rotated weekly, with a "diagnostic mode" in preferences that increases verbosity. A small "show recent activity" view in settings would help debugging without exposing internals to the regular UI.

### 11. Tool call validation strategy
When Claude returns a tool call with malformed parameters, what's the recovery? Recommendation: tool-result error response that explains the malformation; Claude self-corrects on the next turn. After two failed tool calls in a row, the orchestrator drops back to a chat reply asking the user for clarification.

### 12. Streaming vs. non-streaming for chat
Streaming AI responses feel faster. But streaming complicates tool-call handling (tool calls can interleave with text). Recommendation: non-streaming for v1, streaming as a polish pass when the rest is stable.

### 13. Localization
Smoory speaks English in v1. The data model and prompts assume English. Open: is multi-language support important? Recommendation: defer entirely. Add as a separate effort post-v1 if needed.

### 14. The widget's small and large variants
The medium widget gets the daily focus card. Open: what do small and large variants show? Recommendation: small = today's primary task only; large = focus card + goal progress bars + next 2 calendar events. Build medium first; small and large after.

---

## Phase 1 model implementation decisions

These choices govern how the SwiftData `@Model` definitions in `Smoory/Smoory/Models/` are written for milestone 1.1. They sit alongside the CloudKit-compatibility rules in `CLAUDE.md` (relationships optional where applicable, no `@Attribute(.unique)`, defaults on every non-optional property, Int-backed enums, macOS 14 floor).

### 1. Hema models deferred to Phase 2

**Decision:** Do not create SwiftData `@Model`s for `CompactMemory`, `MemoryTurn`, `SemanticFact`, or `MemoryProvenance` in milestone 1.1.

**Reason:** `MEMORY.md` describes hema as a separate SQLite database with the `sqlite-vec` extension, not as SwiftData. Hema has its own data layer that will be built in Phase 2. Modeling these as SwiftData entities now would produce dead code and a schema we'd throw away.

### 2. Folder layout: flat `Models/` plus `Models/Types/`

**Decision:** All entity `@Model` files live directly under `Smoory/Smoory/Models/`. All value-type structs and enums live under `Smoory/Smoory/Models/Types/`.

**Reason:** With ~14 entities the flat layout stays scannable. Subfolders by domain (Core/Feed/Memory) add navigation overhead without payoff at this size. Refactor if it grows unwieldy.

### 3. Value types as Codable struct attributes

**Decision:** Value types — `WorkingHours`, `TrackedSignal`, `ReflectiveCadence`, `ToneProfile`, `ToneOverride`, `ProposedAction`, `EntityReference`, `FeedItemProvenance`, `CaptureLink`, `ToolCall`, `ToolResult`, `EmailReference`, `ThreadEvent`, `TimeOfDay` — are declared as `Codable` structs and used directly as SwiftData attributes (including arrays of them).

**Reason:** macOS 14 SwiftData supports Codable structs as attributes natively. This preserves type safety, avoids hand-rolled JSON serialization, and keeps model code readable. JSON-string serialization is reserved for cases where a typed struct cannot represent the data cleanly (see decision 5).

### 4. Primitive arrays used directly

**Decision:** `[String]`, `[UUID]`, and arrays of Int-backed enums (e.g. `[Weekday]`) are used as native SwiftData attributes. No wrapping, no JSON encoding.

**Reason:** SwiftData on macOS 14 supports primitive-array attributes natively. CloudKit's `CKRecord` supports array values for its primitive types. If a CloudKit migration ever exposes an edge case for a specific array, address it then.

### 5. `ProposedAction.parameters` stored as JSON string

**Decision:** `ProposedAction` carries `parametersJSON: String` rather than a typed parameter struct. The same shape applies inside `ToolCall.parametersJSON` and `ToolResult.resultJSON`.

**Reason:** Tool call parameters are heterogeneous — different shape per tool. A typed struct doesn't fit. JSON string is the lightweight option. A typed-decode helper will be added in Phase 2 when tools actually run.

### 6. `ChatMessage.toolCalls` and `toolResults` minimal shape

**Decision:** Define now as Codable structs in `Models/Types/ChatTypes.swift`:

```swift
struct ToolCall: Codable {
    let id: String              // matches Anthropic's tool_use_id
    let toolName: String
    let parametersJSON: String
}

struct ToolResult: Codable {
    let toolCallId: String
    let resultJSON: String
    let isError: Bool
}
```

**Reason:** `ChatMessage` holds `[ToolCall]` and `[ToolResult]`, so the shape must exist now. Fields will be fleshed out in Phase 2 when tools actually run.

### 7. `Profile` singleton via `fetchOrCreate` helper

**Decision:** Do not use `@Attribute(.unique)` on `Profile.id` (CloudKit-incompatible per `CLAUDE.md`). Instead, expose:

```swift
static func fetchOrCreate(in context: ModelContext) -> Profile
```

Always go through this helper rather than instantiating `Profile()` elsewhere. The helper fetches the first existing record or creates one if none exists.

**Reason:** Singleton enforcement moves from a database constraint (forbidden by CloudKit-compat rules) to a code convention.

### 8. `Thread` entity name shadows `Foundation.Thread`

**Decision:** Name the SwiftData entity `Thread` despite the symbol conflict with `Foundation.Thread`. Within the Smoory module, the entity wins; refer to Foundation's thread type as `Foundation.Thread` if it is ever needed.

**Reason:** The spec consistently uses "Thread" for this entity. Modern Swift concurrency uses `Task` and async-await, not `Foundation.Thread`, so the shadowing has near-zero practical cost. Renaming the entity (e.g. to `WorkThread`) would diverge from the spec without payoff.

### 9. Spec `description` fields renamed to `details`

**Decision:** Where `DATA_MODEL.md` specifies a `description: String` field (Role, Goal, Project, RuleAdjustment), the Swift property is named `details` to avoid implicit collision with `CustomStringConvertible.description`.

**Reason:** Avoids accidental override-warnings and reader confusion. Localized rename, not a semantic change. Inline comments mark each rename in the model files.

### 10. SwiftData inverse back-references added where the spec lists only one side

**Decision:** Where the spec lists a relationship from one side only, the matching back-reference is added on the other side under the conventions `parentX` / `pinnedToX` / `attachedToX`. Concretely:

- `CaptureItem.pinnedToProject: Project?` (inverse of `Project.notes`)
- `CaptureItem.attachedToMessage: ChatMessage?` (inverse of `ChatMessage.attachments`)

`@Relationship(inverse:)` is declared on the to-many side.

**Reason:** SwiftData binds bidirectional relationships reliably when the inverse is declared explicitly. The spec's relationship intent is preserved; only the symmetric back-reference is added for the framework's benefit.

### Convention notes (not separate decisions)

- **To-one relationships are optional** (`Role?`, `Project?`, etc.). **To-many relationships are non-optional with a `[]` default**. The CloudKit-compat rule in `CLAUDE.md` is satisfied: the meaningful "optional" case for CloudKit is to-one, and an empty to-many array is the natural representation of "no items."
- **`Person.title` (job title) is renamed to `jobTitle`** to disambiguate from the `title` field used on Goal / Project / Thread / Habit / Todo.
- All UUID `id` fields default to `UUID()` at init. No `@Attribute(.unique)` is used; UUID collision resistance is the primary identity guarantee.

---

## Default Actor Isolation: nonisolated (project setting)

**Decision:** The project's Default Actor Isolation build setting is explicitly set to `nonisolated` (not Xcode's default `MainActor`).

**Why:** Xcode 26 / Swift 6.2 changed the default actor isolation for new app projects to MainActor, which causes every type and extension to implicitly inherit `@MainActor`. This conflicts with SwiftData's nonisolated storage code path — Codable conformances on attribute value types fail to satisfy SwiftData's actor requirements, producing "Main actor-isolated conformance cannot be used in nonisolated context" warnings (errors in Swift 6 language mode).

More fundamentally: Smoory's architecture explicitly wants pipeline work (sensors, triage, enrichment, structuring layer, hema retrieval, tool execution) to run off the main actor to keep the UI responsive. A MainActor-by-default project would force every service to opt out explicitly, which is verbose and error-prone.

**With nonisolated default:**
- Models, value types, and services run wherever appropriate.
- `@MainActor` is added explicitly where needed: view-models that publish UI state, anything that touches `NSWindow` / `NSEvent` directly.
- SwiftUI views still get `@MainActor` from the `View` protocol itself.
- SwiftData `@Model` classes work correctly across actor boundaries (which is what they're designed for).

**Where this lives:** Build Settings → Smoory target → Default Actor Isolation → nonisolated.

If you ever clone this repo on a fresh machine and lose the project file, this setting must be re-applied or the same warnings return.

---

## Phase 2 milestone 2.1 — hema decisions

Hema (long-term memory) was built across three sub-milestones:
- **2.1a:** SQLite + sqlite-vec scaffolding, `HemaService` API, schema migrations, debug commands.
- **2.1b:** `Embedder` protocol with `VoyageEmbedder` as the first implementation, parameterized Settings UI for multiple API keys.
- **2.1c:** Embedding wired into hema writes and retrieval, privacy filter enforced at the SQL boundary, retrieval test that verifies the privacy contract end-to-end.

The decisions below cover all three.

### Swift binding for sqlite-vec: `jkrukowski/SQLiteVec` 0.0.14

**Decision:** Pin the `https://github.com/jkrukowski/SQLiteVec` Swift package at exact version `0.0.14`. This is the canonical Swift binding for `asg017/sqlite-vec` — that latter repo no longer ships Swift bindings (as of the 2.1a build, `bindings/` contains `go`, `python`, `rust` only).

**Why this package:** It bundles its own SQLite via a `CSQLiteVec` C target (no system `libsqlite3` dependency, no version skew with macOS), exposes a `public actor Database` with async `execute`/`query`/`transaction` APIs, has StrictConcurrency enabled (Swift 6 ready), and supports macOS 10.15+ which covers our macOS 14 floor.

**Single-maintainer dependency risk:** `jkrukowski/SQLiteVec` is a small package (~50 stars, single maintainer). If maintenance lapses, our exit path is bounded: the actual quality dependency is the underlying `asg017/sqlite-vec` C source, which is the dominant SQLite vector extension and is actively maintained. The Swift binding layer is thin (essentially: `Database` actor + `execute`/`query`/`transaction` + parameter binding). Replacing it means writing equivalent thin bindings against `asg017/sqlite-vec`'s C API directly — measured in days, not weeks. The risk is real but the blast radius is small.

**Pin spec:** Exact `0.0.14`. Not `from:` — we want explicit consent to upgrade.

### Vector dimension: 1024 (Voyage `voyage-3`)

**Decision:** vec0 virtual tables are dimensioned `float[1024]`, matching Voyage's `voyage-3` default. The original spec called for 300-dim NLEmbedding; that decision is being reconsidered before the embedding layer ships.

**Why 1024 / Voyage:** The cost difference at personal scale (~150–200 API calls/day) is negligible (~cents/month). The retrieval-quality gap between on-device 300-dim and hosted 1024-dim is meaningful enough — especially for cross-topic retrieval and multi-entity disambiguation — that paying for it is worth front-loading rather than discovering a quality issue six months in.

**Swap path preserved.** The `Embedder` protocol still abstracts the embedder. NLEmbedding remains a viable fallback. Switching back changes `embedding float[1024]` → `embedding float[300]` plus re-embedding the corpus (cheap at personal scale).

### Database file location

**Decision:** Hema lives at `URL.applicationSupportDirectory.appendingPathComponent("Smoory/hema.sqlite")`. For the sandboxed app this resolves to `~/Library/Containers/com.assistant.Smoory/Data/Library/Application Support/Smoory/hema.sqlite`. The `Smoory/` subfolder is redundant inside the container but matches the spec literally; harmless.

**Why separate from the SwiftData store:** SwiftData and sqlite-vec don't compose cleanly. Hema benefits from explicit SQL for vector queries. Two database files keep concerns separate and make hema independently inspectable, exportable, and migratable.

**Sandbox:** No additional entitlement required — the app's container is automatically writable.

### Migration system

**Decision:** Migrations are values (`struct Migration { version, description, up }`) registered in a static array on `enum HemaSchema`. `applyPending(to:)` reads `schema_version`, filters migrations whose version is greater, and runs each in its own `db.transaction { ... }` so a failure rolls back rather than leaving the schema half-applied. Migration 1 creates `schema_version` itself plus all initial tables, vec0 virtual tables, and indexes.

**Why this shape:** Adding a new migration is a single struct literal at the bottom of the array — no separate file, no class hierarchy. Versions are strictly ascending integers. Future-me always knows where to look.

### Schema deviation: no `vector BLOB` columns on main tables

**Decision:** The original `MEMORY.md` schema included `vector BLOB` columns on `memory_turns` and `semantic_facts` alongside the parallel `_vec` virtual tables. The 2.1a implementation drops those columns — the vec0 virtual tables ARE the storage, joined by rowid. The duplicate column was never going to be populated.

**Spec sync:** `MEMORY.md` updated in the same commit to reflect this.

### `is_private` column from migration 1

**Decision:** The `semantic_facts` table carries `is_private INTEGER NOT NULL DEFAULT 0` from migration 1, not as a future schema change. The original spec mentioned the flag as a future implementation note; including it now is materially cheaper than retrofitting via migration 2.

**Per-call privacy filtering at the `HemaService` boundary:** Retrieval excludes private facts by default (`includePrivate: false`). Callers — including the orchestrator and any future memory inspection view — must explicitly opt in to see private facts. The default is "exclude private," so a forgetful caller never accidentally leaks private facts to an LLM API. Documented in `MEMORY.md`'s privacy section.

### `HemaService` is a class, not an actor

**Decision:** `final class HemaService: @unchecked Sendable`. Internal serialization is delegated to `SQLiteVec.Database`, which is itself a `public actor` and serializes its own SQL execution. Adding an outer actor or DispatchQueue would be redundant.

**Why class over actor at the service boundary:** Actor at the service boundary complicates injection and testing (every call site becomes async, every mock becomes an actor or a protocol-existential), and the underlying serialization story is already correct at the `Database` level.

### Debug menu: top-level `Debug` rather than `View → Debug`

**Decision:** Three debug commands live in a top-level `CommandMenu("Debug")` rather than nested under SwiftUI's auto-generated `View` menu. Practical equivalence; the macOS-canonical pattern is a top-level Debug menu.

**Items at end of 2.1:** `Dump hema state`, `Hema self-test`, `Test Voyage embedding`, `Hema retrieval test`, `Reset hema` (NSAlert-confirmed). Dividers separate hema-only commands, Voyage-dependent commands, and the destructive Reset.

### `Embedder` protocol — provider-agnostic abstraction

**Decision:** The `Embedder` protocol (`Smoory/Smoory/Memory/Embedder.swift`) is the single point of abstraction for any embedding model. Methods take an `EmbeddingInputType` (`.document` / `.query`) so callers can express whether the text is being stored or used for retrieval — Voyage and other providers tune their embeddings differently for the two cases. A convenience overload defaults `inputType` to `.document` so the storage path stays clean.

**Why provider-agnostic:** Hema must run regardless of whether Voyage, OpenAI, NLEmbedding, or a future local model is the embedder. The protocol shape supports any of them. `VoyageEmbedder` is the first conforming implementation; future implementations slot in at the protocol boundary without touching `HemaService`.

### `VoyageEmbedder` defaults: `voyage-3` (1024-dim, unit-normalized)

**Decision:** `VoyageEmbedder` hardcodes `model = voyage-3` and `dimension = 1024`. Voyage's documentation states `voyage-3` returns unit-normalized embeddings; we rely on that for the L2 → cosine conversion in retrieval. Closure-injected API key (read on every call) so swapping the key in Settings takes effect immediately. Defensive sort of response items by index, dimension validation on every returned vector.

**Why hardcode:** Cleaner than parameterization at this stage. The protocol abstraction is what enables swapping models — by switching the `Embedder` implementation, not by parameterizing `VoyageEmbedder` itself.

### `Embedder` optional on `HemaService` — asymmetric graceful degradation

**Decision:** `HemaService.init(databaseURL:embedder:)` accepts an `Embedder?`. Production passes `VoyageEmbedder()`; nil is reserved for tests. The graceful-degradation behavior splits asymmetrically across writes and reads:

- **Writes:** if the embedder is nil OR an embedding API call fails (missing key, network, 401, 429), the row is still written to the main table. The vec0 virtual table simply does not get a parallel insert. The failure is logged via `print` and the write returns success. The data is preserved; only the retrievability is degraded.
- **Retrieval:** throws on any embedder failure. Without an embedded query there is nothing to compare against; returning empty would silently mislead callers.

**Why asymmetric:** A chat turn vanishing because the network dropped is a worse experience than a retrieval surfacing fewer results because the embedder is unavailable. Writes preserve data; reads surface root cause. A future "backfill missing embeddings" command can re-embed orphaned rows once the embedder is available again.

### `excludePrivate: true` is the default everywhere

**Decision:** Both `retrieveSimilarFacts` (vector retrieval) and `readAllFacts` (structured listing) default to excluding private facts. Callers must explicitly pass `false` to include them.

**Where the filter lives:** Inside `HemaService` SQL itself (`f.is_private = 0` clause). Not a wrapper around the orchestrator, not a per-recipe config, not a documented convention — the safe default is enforced at the boundary closest to the data. A forgetful or malicious caller cannot accidentally leak private facts into an LLM API call. `runRetrievalTest` verifies this contract on every test run: writes one private fact, queries with the default, asserts the private fact does not appear in the result set, and prints `(private fact correctly excluded from default retrieval)` as confirmation.

### L2 distance → cosine similarity in Swift, not in vec0 schema

**Decision:** vec0 virtual tables are created with the default L2 distance metric (no `distance_metric=cosine` option). Retrieval methods convert the L2 distance returned by vec0 to cosine similarity in Swift via `cos = 1 - L2² / 2`, mathematically valid for unit-normalized embeddings.

**Alternatives considered:** Recreating vec0 tables with cosine metric via a migration 2 — rejected for 2.1c since the L2 conversion gives the same ranking AND the same numerical similarity values for unit vectors. If a future quality issue points to non-unit embeddings or numerical drift, migrating to cosine-metric tables is straightforward (drop and recreate; vec0 has no schema-evolution helper, so this is one transactional migration).

### Subquery in fact retrieval to avoid filter starvation

**Decision:** `retrieveSimilarFacts` uses a two-phase SQL: an inner subquery runs vec0's `MATCH` to fetch `overK = max(4*k, 20)` candidates, then the outer JOIN applies structured filters (private, expired, superseded, tags, entities) and re-trims to the requested k.

**Why:** Without overfetching, requesting `k=5` could return 1 result when 4 of 5 vec0 hits get filtered out. The 4× overfetch factor is conservative for personal scale (the entire vec0 table fits anyway); it costs nothing until the corpus grows.

### Settings: `APIKeyViewModel` parameterized by service

**Decision:** Phase 1's `SettingsViewModel` was provider-specific. 2.1b generalized it to `APIKeyViewModel(service:providerLabel:placeholder:)`. The Settings UI renders one section per provider through a shared `APIKeySectionContent` subview. Two `@State`-managed instances exist today (Anthropic, Voyage); adding a third (OpenAI, a local model, etc.) is a one-line addition.

**Trade-off:** `.keyboardShortcut(.defaultAction)` on the per-section Save button was removed in 2.1b because two simultaneous default actions in the same window would conflict. Per-section `SecureField.onSubmit` handles Return-to-save when the corresponding field is focused — same UX, no ambiguity.

### Hema documentation deferred from MEMORY.md

**Decision:** The privacy-filter-at-HemaService-boundary paragraph already lives in `MEMORY.md` (added in 2.1a alongside the schema sync). 2.1c did not add new spec text; the contract was already documented before the implementation.

---

## Decision template (for future additions)

When making a new architectural decision, document it here in this format:

```
## [Topic]

**Decision:** What was decided.

**Alternatives considered:** What else was on the table, and why each was rejected.

**Why X wins:** The reason this option was chosen.

**Trade-off accepted:** What costs come with this choice.
```

Keep this document up to date as decisions evolve. Future-you (and Claude Code) will thank present-you.

---

## Visual Todos surface (added 2026-04-29)

**Decision:** Add a Todos surface to the sidebar as a fifth primary surface. Todos are visible, searchable by title, editable inline, and support one level of subtasks. Parent todos display fractional completion progress (e.g., `3/5`) when they have subtasks. Both the chat path and the surface write to the same SwiftData store via the same set of tools.

**Why:** Real Phase 2 usage of chat-first todo creation revealed that ambient capture works well, but visual scannability and bulk operations don't. Without a list view, verifying what's in the system requires asking "what's on my list?" each time, which is high-friction for routine review. The list view is the trust-and-focus affordance the chat alone cannot provide.

**Trade-off:** Spec principle 3 (conversation as input mechanism) is no longer the only path. It remains the canonical path for ambient capture, but the list is now an equal first-class surface for management. The principle is amended in spirit: *conversation is the canonical input mechanism for capture; visual surfaces are first-class for focused management*.

**Why one level of nesting:** Arbitrary nesting is tempting but empirically rare past two levels in real task management. The constraint keeps queries and UI tractable.

**Why fractional progress, not auto-complete on subtask completion:** The user might have non-subtask work to finish before the parent is "done." Auto-complete on all-subtasks-done overrides user intent. Manual parent-completion preserves intent. The fraction is a progress indicator, not a state machine.

**Source:** User observation during Phase 2 usage period, after milestone 2.2b was committed and chat-driven todo creation was working. Spec amended before milestone 2.2c began so the create_todo tool's design implicitly acknowledges the upcoming Todo subtask model.

**Subtask deletion cascades from parent (added 2026-04-30):** Deleting a parent Todo deletes all its subtasks via `@Relationship(deleteRule: .cascade)`. Reason: subtasks have no meaning detached from their parent; the alternative (orphaned subtasks promoted to top-level) silently surfaces stale work and breaks the user's mental model of the parent-as-unit. Implemented in milestone 2.2.5a alongside the schema migration.

**Soft-delete via isArchived (added 2026-04-30, milestone 2.2.5b):** `delete_todo` is a soft delete: it sets `isArchived = true` + `archivedAt`. The Todo stays in the SwiftData store but is filtered out of the surface and out of `get_open_todos`. Why: keeps a recovery affordance latent (a future "trash" or undo could surface archived todos) and keeps the entity's history for week-review pattern observation. Hard delete is reserved for explicit user "purge" flows that don't exist yet. Archive cascades to subtasks for the same parent-as-unit reason as the cascade-delete rule.

**Defer reasons appended to notes (added 2026-04-30, milestone 2.2.5b):** `defer_todo`'s optional `reason` is appended to the Todo's `notes` field as a single line `[Deferred YYYY-MMM-DD: <reason>]` rather than stored on a separate `DeferralRecord` entity. Why: pattern observation in week-reviews can grep these without joining a side table; the v1 cost of a separate entity exceeds its benefit until pattern observation actually consumes it. Revisit if defer-pattern queries become real.

---

## Phase 3: foreground polling instead of BGTaskScheduler (added 2026-04-30, milestone 3.1)

**Decision:** Phase 3's scheduled-action firing uses a foreground 5-minute `Timer` plus `UNUserNotificationCenter` for the at-time hint, walking back the `BGTaskScheduler` recommendation in DECISIONS.md:244.

**What this means in practice:** When the app is foreground, the timer flips overdue `pending` rows to `firing` every 5 minutes. When the app is closed, `UNUserNotificationCenter` still fires the OS notification at the scheduled time (the OS handles its own timing); the SwiftData status flip happens on next app launch when `processOverdue()` runs. The action consumer in 3.2+ surfaces firing rows to the user; until the user opens the app, only the OS notification has fired.

**Trade-off accepted:** No true background processing. If the user dismisses an OS notification without opening the app, the row stays `.pending` until the app is reopened (the polling-on-launch path catches it). Acceptable for a single-user single-Mac personal assistant where the app is typically running. `BGTaskScheduler` would add real-but-bounded background fire latency, but the implementation overhead (background mode capability, task identifier registration, declarative scheduling) is not worth it before action consumers exist.

**Why now:** Adding `BGTaskScheduler` later is straightforward — `ScheduledActionService.processOverdue()` is the single integration point. Foreground-only first means the 3.1 foundation lands without the macOS background-task machinery that has its own learning curve. Revisit when 3.2+ ships and the gap is felt in real use.

---

## 4.6 — User Lists feature (2026-05-04)

**Decision:** Add `UserList` + `UserListItem` SwiftData entities, 7 chat tools, and a new `Lists` sidebar surface for user-curated collections distinct from `Todo`.

**Why distinct from Todo:** `Todo` is "tactical commitment with deadline/priority". List items are "curated entries in a collection" — books to read, packing checklists, gift ideas. Conflating them via `Todo` + parent grouping would muddy day-review/week-review semantics that operate on `Todo` as commitments.

**Per-list kind** (`checklist` | `notes`) chosen at create time. `notes` kind has the `isCompleted` field on the model but UI hides the checkbox; `complete_list_item` tool returns an error on notes-kind lists rather than silently no-op'ing — surfaces LLM mistakes early. The field is kept on the model so a list can be re-typed `checklist`→`notes` (or vice versa) without data loss.

**Tool tier policy:** writes silent except `remove_from_list` and `delete_list` (destructive → confirmation card). Symmetric with `WriteMemoryFactTool`'s silent fact-write pattern; reserves cards for actions that can't be casually undone. Read tools (`get_lists`, `get_list_items`) silent.

**Name/id resolution** in tools: every write tool that targets an existing list accepts `list_id` (UUID) OR `list_name` (case-insensitive trimmed match). 0 matches → error; 2+ matches → error directing the LLM to use `list_id`. Same dual-key for `add_to_list`. Item-level tools (`complete_list_item`, `remove_from_list`) take `item_id` only — items don't have unique names.

**Naming:** `UserList`/`UserListItem` to avoid `SwiftUI.List` collision in any file that imports SwiftUI. Considered `Listing`/`Roster`/`Catalog`; rejected as semantically less clear.

**Item ordering:** `UserListItem.order: Int` for stable display order. `add_to_list` always appends (sets order to current max + 1). Reordering happens in the UI via drag — no `reorder_list_items` tool in v1.

**Title uniqueness:** not enforced. Two lists named "Reading list" are allowed. `add_to_list` by name returns an error in that case so the user/LLM resolves.

**Duplicate item text:** allowed. Groceries can have "milk" twice if buying two bottles. Dedup left to the user.

**List delete:** soft delete (`isArchived = true`, `archivedAt = now`); items stay attached for restore. UI exposes "Show archived" toggle. Permanent purge deferred to a debug tool if ever needed.

**Item delete:** hard delete. Items are cheap; soft-delete adds UI complexity for no real win.

**Migration:** none — green-field, fictitious data per user instruction. SwiftData auto-handles new entity addition.

**Out of scope for 4.6:** `rename_list` and `reorder_list_items` tools (UI-only for v1), shared/collaborative lists, list templates, list import/export, recurring auto-populated lists.

---

## 4.7 — Apple Reminders.app bidirectional sync (2026-05-04)

**Decision:** Pull v2+ Reminders sync forward. Smoory's checklist-kind UserLists round-trip with `EKCalendar`/`EKReminder` via EventKit. New `RemindersSyncService` performs full reconcile on Smoory-side mutations, on `EKEventStoreChanged` notifications (debounced 300ms), and on user-triggered "Sync now". Sync is gated behind an explicit opt-in Settings toggle that defaults to OFF — no real Reminders.app data is touched until the user flips it on.

**Why pull forward:** Originally deferred per ARCHITECTURE.md §"Apple framework integration". User reported expecting Smoory lists in Reminders.app for cross-device viewing, Siri, lock screen, and CarPlay. The deferral served Phase 1–4 schema bring-up; with the lists feature shipping in 4.6 the gap became real.

**Scope of sync:**
- **Direction:** bidirectional. Smoory-side edits push to EK; Reminders.app edits pull into Smoory.
- **First-run import:** every existing `EKCalendar` of source `.reminder` is imported as a Smoory `UserList` (`kind = .checklist`). Items round-trip from there.
- **Notes-kind UserLists are excluded** — Reminders has no notes-only concept and items in Reminders.app are universally checkable. Notes-kind lists carry a "Local only" badge in the UI and never get an `eventKitIdentifier`. Conversion notes→checklist (no UI for kind change in 4.7) is the path to bring a notes list into sync.
- **Triggers:** push via `.EKEventStoreChanged` (debounced 300ms); fire-and-forget reconcile after every Smoory list/item write; manual "Sync now" toolbar button as fallback.

**Identity:** `UserList.eventKitIdentifier: String?` stores `EKCalendar.calendarIdentifier`; `UserListItem.eventKitIdentifier: String?` stores `EKReminder.calendarItemIdentifier`. Both nullable — notes-kind, pre-permission, or pre-first-sync rows have nil.

**Conflict resolution:** Last-writer-wins (LWW) by timestamp. Smoory uses `updatedAt`; EK uses `lastModifiedDate`. Newer side wins for title, completion state, completion date. Deletions win over edits (if an item is deleted on one side and edited on the other within the same sync window, deletion stands). No conflict UI in 4.7 — silent LWW. Re-evaluate if data loss complaints surface.

**Source for new EK calendars:** `EKEventStore.defaultCalendarForNewReminders()?.source`. If nil (e.g., iCloud signed out), Smoory enters pull-only mode for that session and logs.

**List title collisions on first import:** if an EK calendar's title matches an existing Smoory UserList title, the imported list is named `"<title> (imported)"` rather than silently merging two unrelated lists. User can rename to merge intent later.

**Permission gate:** `NSRemindersFullAccessUsageDescription` Info.plist key. `EKEventStore.requestFullAccessToReminders()` called when the user enables the Settings toggle. Authorization status read from `EKEventStore.authorizationStatus(for: .reminder)` — Smoory persists no permission state of its own. Denied or revoked → reconcile no-ops, lists keep working locally.

**Concurrency:** an actor-based `SyncSerializer` ensures only one reconcile runs at a time. New triggers during a running reconcile coalesce into one follow-up.

**Schema change:** two nullable `String?` fields added to existing entities. Per CLAUDE.md SwiftData rules and the user's stated indifference to migration on fictitious data, no migration plan is shipped.

**Out of scope for 4.7:**
- Per-list "sync this list / not this list" toggle. All eligible lists sync once the global toggle is on.
- Reminders-side priority, notes, URL fields. Smoory's `UserListItem` doesn't model them; ignored on read, never pushed.
- `EKReminder.dueDateComponents` round-trip. `UserListItem` has no due date in 4.7.
- Conflict-resolution UI. LWW silently for now.
- Background sync when the app is fully terminated (EK changes are captured on next launch via reconcile, not by a background scheduler).
- Multiple Reminders source selection UI. Default source only.
- Notes-kind type conversion via tool/UI.
- iOS / iPadOS targets — macOS only.

**Risk surface:** first reconcile against real Reminders.app data is the highest-risk moment. The opt-in gate is the mitigation — sync stays off until the user makes a deliberate choice. LWW + deletion-wins are documented so expectations match behavior.

---

## 4.9 — Availability as `OffPeriod` entity + proactive conflict proposals (2026-05-04)

**Decision:** Replace the Phase 3 stopgap (availability candidates persisted as semantic facts tagged `"availability"`) with a proper `OffPeriod` SwiftData entity, and add a proactive proposal generator that surfaces todo/calendar conflicts when an off-period is confirmed.

**Why now:** The fact-based stopgap fails two things availability needs to be: (1) queryable as a time period — "am I off Tue?" needs range overlap, not vector search over fact bodies — and (2) actionable — when the user states off-time the spec calls for proposals to defer conflicting todos and decline conflicting meetings, not just a passive memory entry.

**Schema:**

```
@Model final class OffPeriod {
    var id: UUID = UUID()
    var startDate: Date = Date()
    var endDate: Date = Date()
    var kindRaw: Int = OffPeriodKind.personal.rawValue
    var notes: String = ""
    var role: Role?
    var sourceCandidateID: UUID?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

enum OffPeriodKind: Int { case vacation = 0, sick, holiday, personal, other }
```

Per CLAUDE.md SwiftData rules: relations optional, no `@Attribute(.unique)`, defaults on non-optionals, Int-raw enum.

**Migration:** none. Existing availability facts (tag `"availability"`) stay in hema unchanged. New writes route through `OffPeriod` only. Fictitious data per the user's standing instruction.

**Candidate flow:** `CandidateAcceptor`'s `.availability` branch flips from writing a `SemanticFact` to inserting an `OffPeriod`. The candidate's `expiresAt` becomes `endDate`; `startDate` defaults to the candidate's `createdAt` when the structuring layer didn't extract one. `sourceCandidateID = candidate.id` for audit.

**Proactive proposal generator:** New `OffPeriodProposalGenerator` (Pipeline/Availability/) fires after each `OffPeriod` insert. Two passes:
1. Open `UserListItem` rows (todo-shaped: due date, priority, role/project/thread anchor) with `dueDate` falling inside `[startDate, endDate]` → write a `FeedItem` of new kind `.offPeriodConflict` with payload referencing the OffPeriod + the todo. Card text: "Defer 'X' until after [end-date]?" Confirming the card invokes the existing `DeferTodoTool` path.
2. Calendar events in the same range via `CalendarService.eventsBetween` → informational `FeedItem` ("Maria meeting Tue 2pm — review whether to keep / move"). No auto-decline since calendar write is spec'd post-v1.

**Chat tool:** `get_off_periods` (silent read) returns active + upcoming periods so the LLM can answer "am I off next week?". Creation continues to flow through the structuring candidate path; tool-side `create_off_period`/`delete_off_period` deferred to 4.9.x if usage justifies.

**UI:** A "Time off" section in Settings lists current + upcoming periods with delete affordance. No dedicated sidebar surface — would be heavy for what's a sliver of calendar-shaped data. Feed renders the proactive cards inline alongside other feed items.

**Out of scope for 4.9:**
- Out-of-office email auto-reply (no email layer yet).
- Auto-decline calendar events. Calendar write is post-v1; conflict cards inform, they don't act.
- Recurring off periods ("every Friday off"). Single windows only.
- Per-role availability matrix. Optional `role` field exists; richer multi-role logic deferred.
- Backfill of pre-4.9 availability facts into `OffPeriod` rows.
- Dedicated sidebar surface for time off.
- Tool-side `create_off_period` / `delete_off_period`.

---

## 4.10 — End-of-day shutdown ritual (2026-05-04)

**Decision:** Add a separate "end-of-day" review session distinct from the existing day review. Day review is reflective (what stood out, themes, mood); end-of-day is operational (what's left undone, tomorrow first-thing, tie up loose ends). Pairs with the existing morning-brief→day-review arc to bracket the day on both ends.

**Why distinct from day review:** Conflating them produces sessions that are too long for either purpose and tonally muddled. End-of-day fires later (~22:30 default), runs 3–5 turns instead of 4–8, focuses on actionable defer/capture rather than reflection, and ends on a quieter "lights out" note.

**Schedule integration:** New `ScheduledActionKind.endOfDay` (raw 5). Settings → "End of day" section follows the existing day-review section pattern (toggle + time picker). `ScheduledActionService` already handles polling, fire-on-due, and deferral for any kind, so the new case threads through unchanged.

**Tools available during the session:**
- `get_open_todos`, `get_calendar_window` — read what's open today + tomorrow's first events.
- `defer_todo`, `update_todo`, `complete_todo` — tie up loose ends on today's incomplete items.
- `create_todo` — capture for tomorrow.
- `write_memory_fact` — only durable observations the user states (rare in this surface).
- `complete_end_of_day` (new) — closes the session, persists a 1–2 sentence summary as a memory turn so it shows up in retrieval the next morning.

**Restricted:** no `create_scheduled_action` during end-of-day (mirrors the day-review restriction — schedule edits happen in main chat to avoid the user fiddling with their schedule while winding down).

**Conversation arc** (3–5 turns):
1. Acknowledge: "How are you closing out?" (LLM-generated, seeded with today's open-todo count + tomorrow's first calendar event).
2. Loose ends: "Anything you wanted to do today that didn't happen?" — defer or capture.
3. Tomorrow first thing: "First thing tomorrow is [meeting]. Anything to prep?" — optional create_todo / capture note.
4. Optional gratitude / single-sentence note.
5. Wrap: "Sleep well." → call `complete_end_of_day`.

**Voice:** Same anti-emoji / anti-exclamation / no-performative-warmth rules as day review (4.0). Slightly more declarative — fewer questions, more affirmations. Session is winding down, not opening up.

**UI:** New `EndOfDayView` sheet, presented from notification tap or Debug-menu trigger. Shell mirrors `DayReviewView` for consistency.

**Out of scope for 4.10:**
- Voice input (lands in 4.11 across reviews).
- Streak/how-many-days-in-a-row analytics.
- Wind-down music / screen-dim hooks.
- Tomorrow-brief auto-trigger (morning brief already has its own schedule).
- LLM-generated opener that pulls richer context (parity with the deferred day-review opener — when that lands, end-of-day adopts the same path).
- Insights generation (week review owns long-arc patterns).

**Sequencing when both fire same evening:** Day review fires at its scheduled time (reflective), end-of-day later (operational). No interlock — user can defer either. Documented expectation: day review at ~21:00, end-of-day at ~22:30.

---

## SwiftData enum-storage migration policy (post-stateRaw lessons)

**Background:** A field-level audit fix (`FeedItem.stateRaw`, F-1) replaced a stored `var state: FeedItemState` with a new `var stateRaw: Int = …` plus a computed accessor. SwiftData's lightweight migration silently dropped existing values — every row's `state` reverted to default `.active`, surfacing as 10 stale morning briefs in the Feed. Fixed via a self-healing sweep, but the underlying landmine remains for any future enum-to-raw conversion.

**Fields currently stored as enum directly (no `*Raw` companion):**
- `Goal.goalType: GoalType`
- `Goal.status: GoalStatus`
- `CaptureItem.kind: CaptureKind`
- `CaptureItem.source: CaptureSource`
- `Habit.targetCadence: Cadence`
- `FeedItem.confirmationTier: ConfirmationTier`
- `Profile.editedBy: ProfileEditedBy`
- `RuleAdjustment.kind: RuleKind`
- `Thread.status: ThreadStatus`
- `Infrastructure.category: InfraCategory`

**Policy for converting any of these to `*Raw: Int` + computed accessor:**

The naive single-release swap (drop `state`, add `stateRaw`) loses data. The safe sequence is:
1. **Release N:** add `*Raw: Int` as a *new* field with default value, alongside the existing stored enum field. Set `*Raw = enumField.rawValue` in any model write paths so both stay in sync. Ship and let users run on it.
2. **Release N+1:** read the enum value from `*Raw`, swap `enumField` to the computed accessor over `*Raw`, and remove writes to the now-vestigial enum store. Lightweight migration on N+1 is safe because every row already has a populated `*Raw`.

Single-user fictitious-data context (current state of Smoory) lets us skip this dance for now — just do `Debug → Reset hema` after the swap. Once we have real users, the two-step migration is mandatory.

**For new fields:** prefer the `*Raw: Int` + computed pattern from the start, mirroring `FeedItem.stateRaw / .state`. Saves the future migration step.

---

## ErrorBus — single shared mutation-error toast (audit fix F-23)

**Decision:** A single app-level `ErrorBus` (`@Observable`, `@MainActor`) owns the active mutation-error toast and is injected via `@Environment(\.errorBus)`. `ContentView` renders a top-anchored `ErrorBannerOverlay` driven by it. Mutation handlers across the app call `errorBus?.report("Couldn't … : …")` instead of `print(…)` and silently swallowing.

**Why:** Pre-fix, many mutation paths (defer, archive, save, complete subtask, …) used the `do { try … } catch { print(…) }` pattern. The user got no signal when something went wrong. A shared bus avoids per-surface `@State` error toggles and lets every site stay one line.

**Latest-wins semantics:** `report(_:)` overwrites the active toast. Toasts auto-dismiss after 4 seconds and have a manual `xmark` close button. No queueing — if two errors fire in quick succession, the user sees the latest. (Acceptable for a personal single-user app; if multiple users / batch mutations land later, we revisit.)

**Scope:** Only mutation failures the user is responsible for understanding (defer, archive, save, complete, sync). Background pipelines (structuring, brief generation, embedding) keep their existing `*FailureCounter` diagnostics in Settings — those aren't actionable in the moment.

---

## FeedItem.stateRaw — durable @Predicate target (audit fix F-1)

**Decision:** `FeedItem` gains a `var stateRaw: Int = FeedItemState.active.rawValue` field. The existing `state: FeedItemState` becomes a computed accessor over `stateRaw` (mirrors the `kindRaw` pattern already in the schema).

**Why:** SwiftData `#Predicate` cannot dereference an enum's `.rawValue` and direct enum comparison on `FeedItemState` crashed the predicate validator. The Feed view's `@Query` previously fetched every `FeedItem` ever created and filtered to `.active` rows in Swift. Adding `stateRaw` lets the predicate filter at the SQLite layer, so the query scales as feed-item producers come online (morning brief, day-review summaries, off-period proposals).

**CloudKit-compat impact:** None. New non-optional `Int` with a default value follows the same rules already in CLAUDE.md (defaults on non-optional properties, no @Attribute(.unique)).

**Migration:** Smoory ships with fictitious data and no production users yet, so no explicit migration step is needed; SwiftData's lightweight migration backfills `stateRaw` from the default for any pre-existing rows on first open.

---

End of spec. Time to build.
