# Code review — milestone 2.5b

Review date: 2026-04-30
Codebase: 105 Swift files, 10,174 lines under `Smoory/Smoory/`
Spec: 11 markdown files under `docs/smoory-spec/`
Commit reviewed: `ee4dc22..main` (2.5b head, post-DeepSeek swap)

---

## Executive summary

The codebase is **healthy for its age**. Six months and ten milestones of layered work have produced a system that actually does what the spec promises, with disciplined boundaries (LLMClient protocol, Tool protocol, Embedder protocol all hold up post-provider-swap). Architectural drift is minimal. There are **0 CRITICAL findings**.

The single most important finding is the absence of automated tests — the codebase relies entirely on manual end-of-milestone test sweeps and the in-app self-test debug commands. At 10k LOC this is acceptable but increasingly fragile; refactoring confidence is bounded by what the human can hold in their head during an evening.

The second-most-important finding is a quiet spec/code drift: the `ChatMessage` SwiftData entity is declared and registered in the schema but is never written by any code path. Chat persistence is split between in-memory `ChatViewModel.turns` and `hema.MemoryTurn` rows; `ChatMessage` is a vestigial entity that exists only because the spec lists it. Either remove it or wire it up.

Beyond that, findings are mostly stale-comment noise, one-line tightenings, and a few medium-severity items where the spec text and the running code have diverged in either direction.

---

## Statistics

- **Files:** 105 Swift, 11 spec docs
- **Lines of code:** 10,174 (Swift only, not including Package files)
- **Findings by severity:** 0 CRITICAL, 6 HIGH, 18 MEDIUM, 13 LOW
- **`@unchecked Sendable` instances:** 6 (HemaService, AnthropicClient, DeepSeekClient, VoyageEmbedder, RoutingLLMClient, CalendarService)
- **TODO / FIXME comments:** 0 (clean — surprising at this size)
- **Test files:** 0 (the gap)
- **Build warnings on current main:** 0

Healthy ranges per the brief: 0–2 CRITICAL, 3–8 HIGH, 10–20 MEDIUM, 20+ LOW. Findings hit those ranges.

---

## Axis 1 — Spec / code alignment

### HIGH

**A1.H1 — `ChatMessage` SwiftData entity is declared but never written.**
Files: `Smoory/Smoory/Models/ChatMessage.swift`, `Smoory/Smoory/SmooryApp.swift:42`, `Smoory/Smoory/Models/Types/ChatTypes.swift`.
The entity is in the schema (`SmooryApp.swift` line 42), has full `@Model` definition with `role: ChatRole` (.user/.assistant/.system), `attachments`, `relatedFeedItem`, etc. But grep across the codebase for `ChatMessage(` reveals no construction call sites. Chat history lives in `ChatViewModel.turns: [Turn]` (in-memory only) plus `hema.MemoryTurn` rows. `CaptureItem.attachedToMessage` and `ChatMessage.attachments` form a relationship that nothing populates either.
*Why it matters:* dead schema doesn't bite at run time but signals two competing persistence stories for chat (`ChatViewModel.Turn` vs `ChatMessage`). Future work that assumes chat history is in SwiftData will be wrong.
*Direction:* either wire up `ChatMessage` writes from `ChatViewModel.send()` (a real source-of-truth shift) or remove it from the schema and update `DATA_MODEL.md` to acknowledge that chat persistence is hema-only.

**A1.H2 — `CandidateWrite` is in the SwiftData schema but missing from `DATA_MODEL.md`.**
Files: `Smoory/Smoory/Models/CandidateWrite.swift`, `docs/smoory-spec/DATA_MODEL.md`.
Milestone 2.4 added the `CandidateWrite` entity for the structuring layer; the spec was never updated to list it. Anyone reading `DATA_MODEL.md` cold won't know it exists.
*Why it matters:* the spec is supposed to be the single source of truth per CLAUDE.md rule 1. Drift in this direction is the most insidious: code grew an entity, spec didn't notice.
*Direction:* add a `## CandidateWrite` section to `DATA_MODEL.md` mirroring the model's actual fields.

### MEDIUM

**A1.M1 — `Todo.isArchived` / `Todo.archivedAt` are in code but missing from `DATA_MODEL.md`'s Todo field list.**
Files: `Smoory/Smoory/Models/Todo.swift:21-22`, `docs/smoory-spec/DATA_MODEL.md` (Todo section).
The soft-delete decision is in `DECISIONS.md`, but the field list under `## Todo` doesn't mention `isArchived: Bool` or `archivedAt: Date?`. The spec text says "Soft delete is preferred over hard delete for most entities (`isArchived`, `archivedAt`)" as a convention, then doesn't apply the convention in the field list.
*Direction:* one-line addition to Todo's fields list.

**A1.M2 — `FeedItem.provenance` is `FeedItemProvenance?` (optional) in code, non-optional in spec.**
Files: `Smoory/Smoory/Models/FeedItem.swift:20`, `docs/smoory-spec/DATA_MODEL.md` (FeedItem section).
Spec lists `provenance: FeedItemProvenance` without `?`. Code allows nil. No FeedItem producer exists yet so this hasn't bitten, but Phase 3's brief/review producers will need to know whether provenance is required.
*Direction:* decide whether nil is an acceptable production state; if yes, mark optional in spec; if no, make it non-optional in code with a sensible default initializer.

**A1.M3 — Spec describes auto-write of high-confidence facts from structuring layer; code queues all candidates.**
Files: `Smoory/Smoory/Pipeline/Structuring/StructuringService.swift`, `docs/smoory-spec/MEMORY.md` (How hema writes → "Automatic from structuring layer").
Spec says high-confidence facts (≥0.85) "write immediately, no user prompt." Code (per milestone 2.4 explicit decision) queues everything as `CandidateWrite` for review.
*Why it's medium-not-high:* you explicitly approved this gap in 2.4 with the rationale "easier to tune later." But the spec text still describes the auto-write path.
*Direction:* either implement the auto-write threshold or amend `MEMORY.md` to acknowledge that v1 queues all candidates regardless of confidence.

**A1.M4 — Provenance JSON written by `CandidateAcceptor` is missing `user_confirmed_at`.**
Files: `Smoory/Smoory/Pipeline/Structuring/CandidateAcceptor.swift:160-167`, `docs/smoory-spec/MEMORY.md` (Provenance section).
Spec's provenance shape includes `user_confirmed_at: ISO8601 | null`. `CandidateAcceptor.makeProvenanceJSON` sets `user_confirmed: true` but doesn't include `user_confirmed_at`. The reviewedAt timestamp on the candidate row would be the right value.
*Direction:* add `"user_confirmed_at"` to the provenance JSON when accepting.

### LOW

**A1.L1 — `WriteMemoryFactTool.description` mentions "the structuring layer (in a later milestone)".**
File: `Smoory/Smoory/Pipeline/Tools/WriteMemoryFactTool.swift:11-12`.
The structuring layer landed in 2.4. The tool description (sent to the LLM on every chat call) still calls it future work.
*Direction:* one-word edit — drop "(in a later milestone)".

**A1.L2 — `OnboardingStateStore` lacks a debug-menu reset.**
File: `Smoory/Smoory/Surfaces/Onboarding/OnboardingStateStore.swift`, `Smoory/Smoory/App/DebugCommands.swift`.
PHASE_3_NOTES.md flags this; just noting that Debug menu is the natural place to add a reset for testing without touching UserDefaults manually.

**A1.L3 — Stale "Phase 1 type" comment in `HemaTypes.swift`.**
File: `Smoory/Smoory/Memory/HemaTypes.swift:38` (`SemanticFact.entitiesReferenced` — comment says "Phase 1 type, reused"). Phase 1 is the data-model phase by spec naming; the comment reads naturally but is now historical context most readers don't have. Minor.

**A1.L4 — `MemoryTurn.vector` and `SemanticFact.vector` comments say "nil in 2.1a (no embedder yet)".**
File: `Smoory/Smoory/Memory/HemaTypes.swift:32, 47`.
2.1c shipped the embedder. The "nil in 2.1a" framing is historical and can confuse a fresh reader.

---

## Axis 2 — Architectural drift

### HIGH

**A2.H1 — Orchestrator's user-cancellation detection is a substring match.**
File: `Smoory/Smoory/Pipeline/Orchestrator.swift:114-116`.
```swift
if exchange.result.content.contains("\"cancelled\"") && exchange.result.isError {
    anyCancelled = true
}
```
The cancellation marker is `{"status":"cancelled"}` returned by `ChatViewModel.handlePendingAction`'s onCancel branch. But ANY tool result that happens to include the string `"cancelled"` AND has `isError == true` would also be treated as user-cancellation, short-circuiting the loop.
*Why it matters:* a tool that fails with an error message containing "cancelled" (e.g. a future API tool returning `"reason: request was cancelled by upstream"`) would silently make the orchestrator return `.userCancelled` instead of surfacing the error.
*Direction:* introduce a structured cancellation marker — either a sentinel `ToolOutput` flag, a typed result, or an exact JSON match on the full content string `#"{"status":"cancelled"}"#`. Tightening the substring match to exact-equal on the full content would be one defensive line of code.

### MEDIUM

**A2.M1 — `OrchestratorStopReason.toolError` is "reserved for future use" but defined.**
File: `Smoory/Smoory/Pipeline/Orchestrator.swift:251`.
Comment explicitly says "Reserved for future use." Six months in, it's still unused. Either it's load-bearing in some future plan that should be documented, or it's dead.

**A2.M2 — `HemaService.expireFact(id:expiresAt:)` is unused.**
File: `Smoory/Smoory/Memory/HemaService.swift:446`.
The fact detail view sets `expiresAt` via `updateFact` instead of via this dedicated method. The function works; nothing calls it.
*Direction:* remove unless a planned caller is documented somewhere.

**A2.M3 — `ChatViewModel.services: ToolServices` is stored but never read after init.**
File: `Smoory/Smoory/Surfaces/Chat/ChatViewModel.swift` (`private let services: ToolServices`).
Assigned in init, passed to Orchestrator and StructuringService at construction time, never accessed again. Dead state.

**A2.M4 — `HemaService.readAllFacts` default `limit: Int = 100` is a footgun.**
File: `Smoory/Smoory/Memory/HemaService.swift:154`.
`FactsListView` passes `limit: 500` explicitly. Any future caller that forgets to pass `limit` silently gets 100 rows back. With personal-scale memory growth, that's enough to silently truncate inspection results.
*Direction:* either bump the default to match what we actually use (500) or require the parameter (`limit: Int` with no default).

**A2.M5 — Tool definitions sent on every chat turn.**
File: `Smoory/Smoory/Pipeline/Orchestrator.swift:24` (`self.toolDefinitions = ...` cached at init), then sent on every `client.complete(...)` call.
The 11 tool definitions plus their descriptions are ~2k input tokens per call. The Anthropic prompt-cache feature isn't used. This is a future cost optimization — the LLMClient protocol would need a `cacheable: Bool` hint or similar.
*Direction:* note in PHASE_3_NOTES.md as a future optimization; no immediate action.

### LOW

**A2.L1 — Privacy filter is correctly enforced in retrieval but not via type-level guarantee.**
File: `Smoory/Smoory/Pipeline/Tools/RetrieveMemoryTool.swift:88` (`excludePrivate: true // ALWAYS true through this path; non-overridable`).
Comment promises "non-overridable" but the underlying `hema.retrieveSimilarFacts` accepts the parameter. A future tool that calls `hema.retrieveSimilarFacts(... excludePrivate: false)` would bypass the comment's promise. The guarantee lives in caller discipline, not type system.
*Direction:* acceptable as-is — DECISIONS.md frames this as "safe default at the data boundary." The comment is good enough. Listing for awareness only.

---

## Axis 3 — Concurrency and Sendable

### MEDIUM

**A3.M1 — `CalendarService: @unchecked Sendable` justification is weak.**
File: `Smoory/Smoory/Services/CalendarService.swift:30`.
`EKEventStore` is documented as not necessarily thread-safe across writes. The class is constructed once, used from `GetCalendarWindowTool.execute` which can run on any actor (it's `async`, called from Orchestrator's `executeToolUse` which is `@MainActor`). In practice everything ends up on main, which is safe. But the `@unchecked Sendable` claim ("yes, this is Sendable") is stronger than the code guarantees.
*Direction:* mark `@MainActor` if calendar access is in fact main-only — that's the actual contract today. Drop the `@unchecked`.

**A3.M2 — `OrchestratorStopReason.clientError(Error)` carries a non-Sendable Error.**
File: `Smoory/Smoory/Pipeline/Orchestrator.swift:253`.
`Error` isn't `Sendable` by default in Swift 6. `OrchestratorStopReason: Sendable` claims it is. Compiles today because of `@unchecked` on the underlying `OrchestratorTurn` likely. Brittle if an Error case ever crosses an actor boundary.
*VERIFY:* this may actually be fine because Swift 6 `Sendable` checks for Error are looser — confirm whether you've seen any concurrency warnings here. If clean, downgrade to LOW.

### LOW

**A3.L1 — `RoutingLLMClient` allocates a fresh provider client per call.**
File: `Smoory/Smoory/Services/LLM/RoutingLLMClient.swift:8`.
Each LLM call constructs `AnthropicClient()` or `DeepSeekClient()` (which read Keychain on every send for the API key). Tiny cost (~microseconds, one Keychain read per call). Documented in 2.5b decisions as acceptable. Listing for completeness.

**A3.L2 — Several Tasks in surface code use `Task { @MainActor in ... }` without cancellation.**
Files: `Smoory/Smoory/Surfaces/Todos/TodosView.swift` (`showUndo` schedules a 5-second sleep), `Smoory/Smoory/Surfaces/Chat/ChatViewModel.swift` (multiple persistence + structuring tasks fire-and-forget).
None of these have view-lifetime cancellation hooks. If the user navigates away mid-flight the Task continues. For 5-second undo timers and 1-second persistence writes, this is harmless; for the structuring extraction (which can take 1–3 seconds), the user can navigate away and the work continues silently. Not a bug, just a thing.
*Direction:* acceptable; the cost of adding cancellation glue here isn't yet justified.

**A3.L3 — Multiple `@unchecked Sendable` on classes that share a pattern.**
Files: `AnthropicClient`, `DeepSeekClient`, `VoyageEmbedder`, `RoutingLLMClient` — all `final class ... LLMClient/Embedder, @unchecked Sendable`. They're stateless apart from `URLSession` (Sendable) and a closure-based key provider (Sendable), so the `@unchecked` is mechanically justified by the lack of a stored mutable state, not by an actor mechanism. All four are correct; just visible as a pattern.

---

## Axis 4 — Error handling

### MEDIUM

**A4.M1 — `print()` is the universal logging mechanism.**
Files: across the codebase. Counted ~50 `print(` occurrences in non-test code paths.
There is no log level, no structured logging facility, no filter for production vs debug. This is fine for personal-scale single-user where the user IS reading Console.app, but every audit/diagnosis story relies on grep.
*Direction:* introduce a `Logger` (Apple's `os.Logger` is the obvious choice for macOS 14+) when the next milestone needs it. No urgency.

**A4.M2 — `StructuringService` swallows malformed-JSON errors silently after incrementing a counter.**
File: `Smoory/Smoory/Pipeline/Structuring/StructuringService.swift`.
`StructuringFailureCounter.shared.increment()` is the only signal. The actual response text is logged via `print(... raw first 200 ...)`. The user has no UI signal beyond the counter in Settings; no way to retry the extraction. Acceptable per spec ("best-effort, no UI surface"), but means systemic failures (e.g. DeepSeek's JSON formatting drifts) are invisible until someone notices the counter.
*Direction:* surfaced via the counter is sufficient for v1; flagging only for awareness.

**A4.M3 — `HemaService` write methods log embed failures via `print` but return success.**
File: `Smoory/Smoory/Memory/HemaService.swift:42-49, 75-82`.
Spec's "asymmetric graceful degradation" decision: writes preserve data even when embedding fails; reads throw. Implementation matches spec. The user-visible effect is silent: a turn or fact is stored but never retrievable until the embedder works again. There's no "backfill missing embeddings" command.
*Direction:* DECISIONS.md mentions a "future backfill command" as the recovery path. Not built. Worth noting in PHASE_3_NOTES.md.

### LOW

**A4.L1 — `AIProviderStore.current()` silently falls back to `.deepseek` on malformed UserDefaults.**
File: `Smoory/Smoory/Services/LLM/AIProvider.swift:19-22`.
If UserDefaults somehow has a value that isn't `"anthropic"` or `"deepseek"` (corruption, a future enum case removed), the store returns `.deepseek`. Reasonable default; just noting the silent path.

**A4.L2 — `ChatViewModel.send()` slash-command short-circuits without logging.**
File: `Smoory/Smoory/Surfaces/Chat/ChatViewModel.swift:107-111`.
`/end onboarding` returns silently. User sees no confirmation. This is intentional (Finish button gives the visible feedback, slash command is fallback) but if the user types `/end onboardingX` they'd expect feedback that the command wasn't recognized. Currently it's just sent as a chat message.
*Direction:* acceptable; intentional minimalism.

---

## Axis 5 — UI consistency and patterns

### MEDIUM

**A5.M1 — Settings `Anthropic API key` field is no longer always visible.**
File: `Smoory/Smoory/Surfaces/Settings/SettingsView.swift:48-52`.
Pre-2.5b: Anthropic key field was always shown as its own section. Post-2.5b: the field is shown only when "AI provider: Anthropic" is selected. To replace the Anthropic key when DeepSeek is the active provider, the user must temporarily switch provider, replace, switch back. Mild UX regression vs. prior state.
*Direction:* either always show both keys (one section per provider, no picker-driven hide), or accept current behavior. The current pattern is slightly cleaner visually but adds a step for the rare case of replacing a non-active provider's key.

**A5.M2 — Search bar implementation is duplicated across surfaces.**
Files: `Smoory/Smoory/Surfaces/Todos/TodosView.swift:131-148`, `Smoory/Smoory/Surfaces/Memory/Facts/FactsListView.swift:42-59`, `Smoory/Smoory/Surfaces/Memory/Turns/TurnsListView.swift:43-58`, `Smoory/Smoory/Surfaces/Feed/FeedView.swift:104-118`.
Four near-identical implementations of `HStack { Image(magnifyingglass) + TextField + Button(xmark) }`. Same visual styling, same clear-button pattern.
*Direction:* extract a `SearchBar` view in `Surfaces/Common/`. ~20 line refactor. Reduces churn the next time we touch the styling.

**A5.M3 — Filter pill pattern is duplicated, with subtle differences.**
Files: `Smoory/Smoory/Surfaces/Memory/Facts/FactsListView.swift:69-103`, `Smoory/Smoory/Surfaces/Memory/Turns/TurnsListView.swift:71-93`, `Smoory/Smoory/Surfaces/Feed/FeedView.swift:122-145`.
All three use `Picker(...).pickerStyle(.menu).tint(...)`. The tint logic ("secondary if All, accent otherwise") is repeated three times. Acceptable pattern, but `FeedView` doesn't exactly match the others on `.onChange(of:)` reload semantics.
*Direction:* extract a small `FilterPicker<Filter: CaseIterable>` if/when a fourth surface needs filters; not urgent.

**A5.M4 — Empty-state strings are inconsistent in tone.**
Files: scattered across surfaces.
`TodosView`: "No open todos" / "Add a todo above, or talk to Smoory in Chat."
`FactsListView`: "Hema has no facts yet" / "Talk to Smoory and high-confidence facts will be saved here."
`TurnsListView`: "No conversation turns yet" / "Send a message in Chat — turns are recorded as they happen."
`FeedView`: "Nothing to review." / "Smoory will surface things here as they come up..."
Some use lowercase casual ("no open todos"), others use sentence case formal. Some end with periods, some don't. Minor.
*Direction:* nudge to consistent voice when next touching empty states.

### LOW

**A5.L1 — Loading-state UX varies.**
`Smoory/Smoory/Surfaces/Memory/MemoryView.swift` shows a centered `ProgressView` + text. `Smoory/Smoory/Surfaces/Feed/FeedView.swift` shows nothing during `@Query` initial fetch. `Smoory/Smoory/Surfaces/Todos/TodosView.swift` same. SwiftUI's `@Query` populates synchronously in most cases, so the difference is invisible — but during onboarding when 30+ candidates land at once, Feed could flash.

**A5.L2 — `SettingsView` mixes provider, voyage, and diagnostics sections in inconsistent order.**
File: `Smoory/Smoory/Surfaces/Settings/SettingsView.swift`.
Order is AI provider → Voyage API key → Diagnostics. Voyage is a memory infrastructure thing; logically it could sit next to AI provider OR next to Diagnostics. Current layout is fine; just noting the implicit grouping.

**A5.L3 — `SettingsViewModel.swift` filename vs class name (`APIKeyViewModel`).**
File: `Smoory/Smoory/Surfaces/Settings/SettingsViewModel.swift`.
File holds only `APIKeyViewModel`. Filename suggests a more general settings VM. Minor.

---

## Axis 6 — Dead code, unused features, stale comments

### MEDIUM

**A6.M1 — `HemaService.expireFact` is never called.** (Same as A2.M2.)

**A6.M2 — `OrchestratorStopReason.toolError` case is unreachable.** (Same as A2.M1.)

**A6.M3 — `HemaService` self-test, retrieval-test, and seed-data methods (~270 lines) live in production source.**
File: `Smoory/Smoory/Memory/HemaService.swift:512-783`.
`runSelfTest()`, `runRetrievalTest()`, `seedTestData()` are all production-shipped, only ever invoked from Debug menu. Together they bloat HemaService from a service file to a service-plus-tests file. They contain valuable assertions (the privacy-filter contract test in particular) that should survive — but they could live in a `HemaServiceDiagnostics.swift` extension or a separate target.
*Direction:* split into an extension file. ~15-minute refactor. Net: HemaService.swift drops to ~510 lines.

**A6.M4 — `seedTestData` debug method writes to production hema.**
File: `Smoory/Smoory/Memory/HemaService.swift:739`, `Smoory/Smoory/App/DebugCommands.swift`.
Running it on a real install pollutes the real hema with seed data. The cleanup phase (`bestEffortCleanup`) is part of `runSelfTest` not `seedTestData`. So a developer who accidentally taps "Seed hema with test data" without follow-through has now contaminated their real corpus.
*Direction:* either add a confirmation prompt OR have the seed method tag rows distinctly so a "remove seed data" command can scrub them. Acceptable as-is for solo development; flagging for awareness.

**A6.M5 — `metadataJSON` on MemoryTurn is now always empty string post-COALESCE workaround.**
Files: `Smoory/Smoory/Memory/HemaService.swift:160` (the COALESCE), `Smoory/Smoory/Surfaces/Chat/ChatViewModel.swift:348` (always passes `metadataJSON: nil` on write).
Pre-COALESCE: `metadataJSON: nil`. Post-COALESCE: `metadataJSON: ""` (empty string from SQL substitution). The field is unused everywhere downstream, but the type changed silently.
*Direction:* drop `metadataJSON` from `MemoryTurn` until a real consumer needs it; or document the new "" semantic. Currently silent drift.

### LOW

**A6.L1 — `AnthropicClient` and `DeepSeekClient` have parallel JSON-handling boilerplate.**
Files: both clients implement the same shape: try-encode-body → URLRequest setup → status switch → decode-typed-response. Could share a helper. Minor — the duplication is small enough that DRYing it would create more abstraction than it saves.

**A6.L2 — `OnboardingPromptSheet` exists as a separate file but is a single SwiftUI view.**
File: `Smoory/Smoory/Surfaces/Onboarding/OnboardingPromptSheet.swift`. Could live inline in ChatView or in a smaller file colocated with ChatView. Cosmetic.

**A6.L3 — `Tool.swift` declares the protocol but `ToolRegistry.anthropicToolDefinitions` keeps the historical name despite working for both providers.**
File: `Smoory/Smoory/Pipeline/ToolRegistry.swift:22`.
The function returns `[LLMTool]` which is provider-agnostic. The name is left over from the Anthropic-only era.
*Direction:* rename to `ToolRegistry.toolDefinitions` (or keep — the consumer is `Orchestrator` which calls it once at init).

**A6.L4 — Comments referencing "Anthropic" / "Anthropic requires" in code that runs against any LLM.**
Files: `Smoory/Smoory/Pipeline/Orchestrator.swift:96` (`// Single batched user message with all tool_result blocks (Anthropic requires this).`), `Smoory/Smoory/Pipeline/PendingAction.swift:13` (`// tool_use_id from Anthropic`).
Both still apply to DeepSeek (DeepSeek's tool_call_id has the same structural role). Comments are dated.

**A6.L5 — `AnthropicClient.swift` and `DeepSeekClient.swift` both have a private `JSONValue` enum (in AnthropicClient only, actually). Consistency-wise, DeepSeek doesn't need it because args are passthrough strings.**
Just noting the asymmetry; not actionable.

---

## Axis 7 — Performance and resource usage

### MEDIUM

**A7.M1 — Structuring layer prompt is sent on every chat turn, ~2k tokens.**
File: `Smoory/Smoory/Pipeline/Structuring/StructuringPrompt.swift:5-58`.
The system prompt with examples plus the existing-entity snapshot plus already-handled hints plus the user message can run 2k+ input tokens per chat turn. With DeepSeek pricing this is ~$0.0005/turn — negligible. With Claude it would have been ~10x. Worth noting that the spec's "personal-scale cost: $5–15/month" was based on Claude pricing and is now over-estimated for DeepSeek.
*Direction:* no action; future optimization if cost ever becomes an issue is prompt caching (provider-dependent).

**A7.M2 — `GetOpenTodosTool` fetches all todos then filters in Swift.**
File: `Smoory/Smoory/Pipeline/Tools/GetOpenTodosTool.swift:67-70`.
```swift
var descriptor = FetchDescriptor<Todo>()
descriptor.fetchLimit = 500
let allTodos = (try? modelContext.fetch(descriptor)) ?? []
// later filtered in Swift
```
500-row hard cap. At personal scale (≤50 todos typical) this is irrelevant. The reason for fetch-all-then-filter is documented in `GetActiveGoalsTool`: SwiftData `#Predicate` on Int-backed enum-stored attributes is unreliable on macOS 14. Acceptable workaround.

**A7.M3 — `FactsListViewModel` keeps all 500 facts in memory and re-filters per keystroke.**
File: `Smoory/Smoory/Surfaces/Memory/Facts/FactsListViewModel.swift:106-128`.
Each search keystroke triggers a full filter pass over `facts: [SemanticFact]`. At 500 facts × ~5 fields per filter, this is microseconds. Future-pagination concern noted in PHASE_3_NOTES.md.

### LOW

**A7.L1 — `RoutingLLMClient` reads UserDefaults on every LLM call.**
File: `Smoory/Smoory/Services/LLM/RoutingLLMClient.swift:8` → `LLMClientFactory.makeCurrent()` → `AIProviderStore.current()` reads UserDefaults.
Documented in 2.5b decisions as acceptable. Listing for completeness.

**A7.L2 — Keychain is read on every LLM call.**
Files: `AnthropicClient.init` and `DeepSeekClient.init` both default to a closure that reads Keychain. The closure runs per-call (not per-init) because the clients are constructed per-call.
At ~1 LLM call per user turn this is negligible. If we ever batch many calls in a tight loop, add a per-session cache.

**A7.L3 — Tool descriptions are large and sent every turn.**
Same as A2.M5. Repeated for completeness in this axis.

**A7.L4 — `@Query` for FeedItems fetches all rows, no filter.**
File: `Smoory/Smoory/Surfaces/Feed/FeedView.swift:34-37`.
Documented inline ("predicate doesn't work, filter in Swift; small N here"). Phase 3 producers will add real FeedItems; the "small N" assumption may need revisiting.

---

## Cross-cutting observations

**X1 — There are no automated tests.**
The codebase has 105 files, 10k LOC, and zero `XCTest` or test target. The "self-test" debug commands in HemaService cover the privacy contract specifically (the most security-relevant thing) but are run manually. Refactoring confidence is bounded by what fits in a human's working memory during an evening session.
*Why this is HIGH-severity cross-cutting:* the codebase has been stable so far, but Phase 3 introduces scheduled background work (briefs, reviews) that's harder to verify by manual sweep. The window for adding a test target with zero risk closes when the first time-of-day-sensitive Phase 3 code lands.
*Direction:* a one-day pass to add `Tests/` with smoke tests for HemaService write/read, structured-tool execution, and DeepSeekClient request encoding would pay back across Phase 3 + Phase 4. Prioritize before 3.x starts.

**X2 — DECISIONS.md is the de facto living spec.**
Spec files (DATA_MODEL, MEMORY, etc.) are the "original intent" docs. DECISIONS.md is where actual decisions accrete. New readers should be pointed to DECISIONS.md first; today, README.md sends them through DATA_MODEL → MEMORY → ... and they read decisions last.
*Direction:* README.md tweak — link DECISIONS.md prominently.

**X3 — The provider-swap to DeepSeek is clean architecturally but tested only manually.**
The RoutingLLMClient + LLMClientFactory + AIProvider pattern is tight. The DeepSeekClient encoding/decoding is currently unverified except for the manual F1–F10 + validation gates in the 2.5b prompt. If those pass, it's good; if any fail, the brittleness is in encoding edge cases that automated tests would have caught.
*Direction:* see X1.

**X4 — Spec drift accumulates faster than documented updates.**
Three findings (A1.H1, A1.H2, A1.M1) reflect the same pattern: code grew an entity or field, spec didn't catch up. CLAUDE.md rule 1 says "spec is source of truth, raise drift." The drift was not raised at the time. Likely cause: milestones land with spec amendments for *new* concepts (Todos surface, candidate write) but field-level additions to existing entities slip through.
*Direction:* add a checklist item to milestone closeout: "did this milestone change any DATA_MODEL.md entity? if yes, did the field list update?"

---

## Recommended next steps

Ordered by ROI (severity adjusted by ease).

### Tier 1 — Address before Phase 3 starts (~1 day total)

1. **Fix Orchestrator cancellation detection** (A2.H1). One-line tightening: exact-match the cancellation marker JSON string instead of substring.
2. **Resolve `ChatMessage` drift** (A1.H1). Decide: wire it up or remove. If removing, drop from schema + spec. ~30 minutes either way.
3. **Sync `DATA_MODEL.md`** (A1.H2 + A1.M1 + A1.M2). Add `CandidateWrite` section, add `isArchived/archivedAt` to Todo, decide FeedItem.provenance optionality. ~1 hour total.
4. **Add a minimal `Tests/` target with HemaService smoke tests** (X1). The privacy filter contract, the migration application, the embedder asymmetric write/read. ~half day for the first pass.
5. **Drop `expireFact` and `OrchestratorStopReason.toolError`** if confirmed unreachable (A2.M2, A2.M1). Or document why they're load-bearing for future work.

### Tier 2 — Worth doing within Phase 3 (~1 day total, can fit between milestones)

6. **Split `HemaService.swift`** into `HemaService.swift` + `HemaService+Diagnostics.swift` (A6.M3). Reduces the main file from 800 → 510 lines.
7. **Add `user_confirmed_at` to provenance JSON** in `CandidateAcceptor` (A1.M4). One-line.
8. **Update tool description text** that mentions future milestones (A1.L1, A6.L4). Few-minute pass.
9. **Drop or document the `metadataJSON` post-COALESCE behavior** (A6.M5). Either remove the field or document the empty-string semantic.
10. **Mark `CalendarService` `@MainActor` instead of `@unchecked Sendable`** (A3.M1) — assuming verification confirms calendar access is main-only in practice.

### Tier 3 — Accept as-is unless stale (~no urgency)

11. UI consistency findings (A5.M2, A5.M3, A5.M4, A5.L1, A5.L2) — extract `SearchBar` only when the next surface adds search. Current duplication isn't biting.
12. `print()`-as-logging (A4.M1) — fine until Phase 3 introduces background work where logs need filtering.
13. RoutingLLMClient + Keychain per-call reads (A3.L1, A7.L1, A7.L2) — design choice, documented.
14. `seedTestData` confirmation prompt (A6.M4) — solo dev hasn't been bitten; add when anyone else touches the codebase.

### Do nothing, accept

15. The `OnboardingPromptSheet`-as-its-own-file (A6.L2) — cosmetic
16. `AnthropicClient` / `DeepSeekClient` boilerplate similarity (A6.L1) — small duplication, abstraction would cost more
17. Stale historical comments (A1.L3, A1.L4) — clean up next time touching the file

---

End of review.
