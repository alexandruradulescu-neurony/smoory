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

## Phase 2 milestone 2.1a — hema scaffolding decisions

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

**Items in 2.1a:** `Dump hema state`, `Hema self-test`, `Reset hema` (with NSAlert confirmation — dev escape hatch for 2.1b/2.1c iteration).

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

End of spec. Time to build.
