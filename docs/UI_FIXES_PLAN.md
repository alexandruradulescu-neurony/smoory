# UI Fixes Plan — remaining 21 findings from the audit

**Status:** Plan only. Do not implement until the user says "continue" after `/compact`.

**Source:** Background UI audit run after the bug-fix batch (commit `306d2f8`) shipped the top 4 findings. The audit returned 25 issues; 4 are fixed; this doc covers the remaining 21.

**How to use post-compact:** Read this file end-to-end. Each finding has a file path, problem, fix, and effort. Execute in the order under "Plan of attack" below. Commit per logical group. Build clean before each commit. Relaunch Smoory after each commit (canonical binary at `/Users/alex/Library/Developer/Xcode/DerivedData/Smoory-awmhbyagcsebmraomliojfvpalyb/Build/Products/Debug/Smoory.app`).

The most recent main commit referenced by this plan is `306d2f8`. If `git log --oneline -5` shows commits past that, this plan may be stale — re-run the audit (Explore agent) to refresh.

---

## Findings (21)

### Architectural / cross-cutting (4)

#### F-23 — Silent error swallowing across mutations [L]
**Where:** several handlers in `Surfaces/Todos/`, `Surfaces/Lists/`, `Surfaces/DayReview/DeferPopover.swift`, `Surfaces/Feed/`. Examples: `TodoDetailView.completeSubtask`, `DeferPopover.commit`, `archiveSubtask` paths.
**Problem:** mutations catch errors and `print()` only; user sees no feedback.
**Fix:** introduce a small `ErrorBannerOverlay` (similar to `UndoBanner`) at the top of `ContentView` driven by an `@Observable` `ErrorBus` injected via env. Each mutation handler calls `errorBus.report("Couldn't complete: \(error)")` on catch.
**Effort:** L (new shared component + wiring across ~8 files).

#### F-24 — Empty-state inconsistency [M]
**Where:** Feed (no candidates / no items), Todos (`emptyState` view), Lists (`emptyListsState` + `UserListDetail.emptyState`), Memory (loading + no facts).
**Problem:** each surface renders its empty state with different icon families, copy length, CTA presence.
**Fix:** standardize on the existing `EmptyState` view in `Surfaces/Common/EmptyState.swift`. Replace the ad-hoc empty-state VStacks with `EmptyState(symbol: ..., headline: ..., detail: ..., cta: ...)`.
**Effort:** M (find each callsite, swap to `EmptyState`, remove dead helpers).

#### F-25 — Tab-switch scroll/filter reset [S]
**Where:** sidebar `Surface` switching in `ContentView.swift`.
**Problem:** Some surfaces preserve scroll/filter on re-entry (Feed), others don't (Memory `showPrivate`).
**Fix:** lift surface-level state (filter, scroll position via `ScrollViewReader.scrollPosition`) into the surface's view-model held at `@State` in the parent. Memory's `showPrivate` moves into `MemoryViewModel`.
**Effort:** S, but covered also by F-15 below.

#### F-12/13/22 (already fixed for #22) — Chat composer ergonomics [S]
**#22 is shipped (voice mic).**
**Remaining (F-12/13):** `ChatView.swift:139` — TextField with `axis: .vertical` and `lineLimit(3...12)` grows unbounded; no max frame height; on long pasted content the composer pushes the transcript off-screen.
**Fix:** clamp with `.frame(maxHeight: 200)` and wrap in `.scrollContentBackground(.hidden)` if needed. Verify `.lineLimit(3...12)` interacts with the frame cap (it should — lineLimit caps ROWS, frame caps PIXELS; both apply).
**Effort:** S.

---

### Surface-specific (17)

Grouped by file for batched commits.

#### Lists

##### F-9 — Priority representation drift [S]
**Where:** `Surfaces/Todos/TodoRow.swift:35` uses `todo.priorityBucket`; `Surfaces/Lists/UserListItemRow.swift:46-51` uses `priorityBucket` indirectly via `showsBadges`; `Surfaces/Todos/TodoBadges.swift:33` (`PriorityIndicator.priority: Int`) takes raw Int.
**Problem:** UI splits between `PriorityBucket` enum and raw Int.
**Fix:** standardize on `priorityBucket` in all SwiftUI rows (it already maps to Int internally). Make `PriorityIndicator` accept `PriorityBucket` instead of `Int`. Update both callsites.
**Effort:** S.

##### F-10 (FIXED in 306d2f8) — UserListItemDetailSheet height
##### F-11 — Archived list empty state [S]
**Where:** `Surfaces/Lists/ListsView.swift` `UserListDetail.emptyState`.
**Problem:** archived list with no items shows "Add an item below to get started." but the input is disabled (read-only when archived).
**Fix:** branch in `emptyState`: if `list.isArchived`, render "This list is archived. Restore it from the header to add items." Otherwise current copy.
**Effort:** S.

##### F-8 — HSplitView column constraints [S]
**Where:** `Surfaces/Lists/ListsView.swift:27-31`.
**Problem:** picker column `minWidth: 220, idealWidth: 260, maxWidth: 360` + item column `minWidth: 360`; in narrow windows total min exceeds available, right pane compresses.
**Fix:** drop `idealWidth` on picker; lower picker `minWidth` to 180; make item column `minWidth: 320` so the layout collapses gracefully.
**Effort:** S.

#### Memory

##### F-14 — Loading state blank [S]
**Where:** `Surfaces/Memory/MemoryView.swift` `loadingView`.
**Problem:** on `.loading` hema state, the view is empty white.
**Fix:** show `ProgressView()` + "Loading memory…" caption, similar to `ChatView.loadingView`.
**Effort:** S.

##### F-15 — `showPrivate` toggle resets on tab switch [S]
**Where:** `Surfaces/Memory/MemoryView.swift` line ~75-77.
**Problem:** `@State` is local to the view; reentry resets.
**Fix:** move into `MemoryViewModel` as `@Observable` property.
**Effort:** S.

#### Settings

##### F-16 — Voyage API key section always visible [S]
**Where:** `Surfaces/Settings/SettingsView.swift:82-83`.
**Problem:** section shows even when Voyage isn't the active embedding provider.
**Fix:** wrap in `if providerVM.selected != .deepseek` (or whatever the actual condition is — verify by reading the section above).
**Effort:** S.

##### F-17 — Day/Week/MorningBrief VMs lazy-init in onAppear [M]
**Where:** `Surfaces/Settings/SettingsView.swift:243-262`.
**Problem:** rapid Settings entry shows toggles briefly disabled while VMs construct.
**Fix:** initialize all three settings VMs eagerly in `init()` (before the body renders), or hold them in app-level state and inject via env.
**Effort:** M (changes init signature).

#### Onboarding

##### F-21 — Sheet width overflow on narrow windows [S]
**Where:** `Surfaces/Onboarding/OnboardingPromptSheet.swift:32`.
**Problem:** `frame(minWidth: 460)`; narrower windows clip.
**Fix:** drop `minWidth`, use `idealWidth: 460, maxWidth: .infinity`. Onboarding sheet is short text — reflow handles narrow windows.
**Effort:** S.

#### Feed (architectural-y, but small)

##### F-1 — `@Query` predicate fragility on FeedItem enum [M]
**Where:** `Surfaces/Feed/FeedView.swift:21-24`.
**Problem:** comment flags that SwiftData `#Predicate` on Int-raw enum is finicky; current workaround filters client-side.
**Fix:** add an explicit `var stateRaw: Int = ...` field on `FeedItem` (mirrors the `kindRaw` pattern), backfill the existing `state` var as a computed accessor, query by `stateRaw == FeedItemState.active.rawValue`.
**Effort:** M (model change + migration-free since Smoory uses fresh data).

##### F-2 — Empty-state placement breaks layout when only one of two lists is empty [S]
**Where:** `Surfaces/Feed/FeedView.swift:67-78`.
**Problem:** empty-state for candidates renders inline; if items list also has rows the empty card looks misplaced.
**Fix:** check both lists; render the global empty-state only when *both* are empty. Otherwise just hide the candidates section.
**Effort:** S.

##### F-3 — FeedItemRow blank summary fallback [S]
**Where:** `Surfaces/Feed/FeedItemRow.swift:38`.
**Problem:** `Text(summary?.title)` (or similar) can render an empty string if summary fails.
**Fix:** use `summary?.title ?? "(no summary)"` or guard the section so it doesn't render at all when nil.
**Effort:** S.

#### Day-review / Week-review / End-of-day

##### F-19 — End-of-day vs Day-review tonal redundancy [S]
**Where:** `Surfaces/EndOfDay/EndOfDaySheet.swift` placeholder + `Pipeline/EndOfDay/EndOfDayPrompts.swift` opener variants.
**Problem:** if both fire same night, the rituals can feel redundant.
**Fix:** in `EndOfDayViewModel.startIfNeeded`, check whether a `dayReview` ScheduledAction with status `.completed` exists for today. If yes, prepend a short context line ("Day review's done — let's tie up loose ends + line up tomorrow.") to the opener so the user feels the operational distinction.
**Effort:** S.

##### F-6 — TodoDetailView silent error on `completeSubtask` [S]
**Where:** `Surfaces/Todos/TodoDetailView.swift` `completeSubtask` (and friends).
**Problem:** errors logged to console only; user sees nothing.
**Fix:** when F-23's `ErrorBus` lands, forward via env. Until then: surface a simple `@State var subtaskError: String?` + alert.
**Effort:** S (independent of F-23 if rolled in alongside).

##### F-7 — DeferPopover silent error [S]
**Where:** `Surfaces/Todos/DeferPopover.swift:42-54`.
**Problem:** `catch` calls `onCancel` silently; user thinks defer worked.
**Fix:** add `@State var error: String?` + alert binding. On error, set message; user sees it before the popover dismisses.
**Effort:** S.

#### Todos

##### F-4 — TodosView relies on TodosViewModel for filtering [S]
**Where:** `Surfaces/Todos/TodosView.swift:7`.
**Problem:** `@Query<UserListItem>` is unfiltered; the view-model filters in Swift. Future refactors could miss the coupling.
**Fix:** add a doc comment at the `@Query` site explicitly stating "client-side filtered by `TodosViewModel.groupedTodos`; do not rely on these rows being todo-shaped."
**Effort:** S (comment only).

##### F-5 — Priority drift (already covered under F-9)

#### General / Cross-surface

##### F-25 — Cross-surface scroll/filter reset (covered under F-15 and F-23 plumbing).

---

## Plan of attack (ordered)

Group commits to minimize blast radius. Each commit should build clean.

### Commit 1 — Quick UI polish (S items, no architecture)
Files: `MemoryView`, `OnboardingPromptSheet`, `FeedItemRow`, `ListsView` (HSplitView + archived empty), `SettingsView` (Voyage section), `TodosView` (doc comment).
Findings: **F-3, F-8, F-11, F-14, F-16, F-21, F-4** (comment).
Effort: ~30 min.
Commit message: `UI polish: empty states, loading, sheet sizing, Voyage section visibility`.

### Commit 2 — Priority representation unified
Files: `TodoBadges.swift` (PriorityIndicator takes `PriorityBucket`), `TodoRow.swift`, `UserListItemRow.swift`.
Findings: **F-5, F-9**.
Effort: ~20 min.
Commit message: `Unify priority rendering on UserListItem.PriorityBucket`.

### Commit 3 — Memory tab state preservation
Files: `MemoryViewModel.swift`, `MemoryView.swift`.
Findings: **F-15** (and partially F-25 — scroll position is bigger; punt to a later pass).
Commit: `Memory: persist showPrivate across tab switches`.

### Commit 4 — Settings VM eager init
Files: `SettingsView.swift` (init).
Findings: **F-17**.
Commit: `Settings: init review-config viewmodels eagerly`.

### Commit 5 — Chat composer max height
Files: `ChatView.swift`.
Findings: **F-12/13** (remaining; F-22 voice already shipped).
Commit: `Chat: cap composer height so long input doesn't push transcript off-screen`.

### Commit 6 — Feed empty state + state predicate
Files: `FeedItem.swift` (add `stateRaw`), `FeedView.swift`.
Findings: **F-1, F-2**.
Effort: M (model field + accessor + migration check — but no migration since fictitious data).
Commit: `Feed: durable stateRaw + dual-list empty-state`.

### Commit 7 — End-of-day opener references day review
Files: `EndOfDayViewModel.swift` (startIfNeeded prepend).
Findings: **F-19**.
Commit: `End-of-day: opener acknowledges already-completed day review`.

### Commit 8 — Error bus + apply to known offenders
Files: new `Common/ErrorBus.swift` + `ContentView.swift` overlay + `DeferPopover.swift` + `TodoDetailView.swift` (couple of handlers) + the known silent catches in Lists/Feed.
Findings: **F-6, F-7, F-23**.
Effort: L (real component + integration).
Commit: `Add ErrorBus + surface mutation errors to user`.

### Commit 9 — Empty-state standardization
Files: every surface's empty state replaced with `EmptyState`.
Findings: **F-24**.
Effort: M.
Commit: `Standardize empty states on the shared EmptyState component`.

### Tail — verify
Run app, smoke-test each surface. If borderline, paste back to user.

---

## Don't-forget reminders

- Project path: `/Users/alex/Code/Smoory/Smoory/Smoory.xcodeproj`
- Build cmd: `xcodebuild -project /Users/alex/Code/Smoory/Smoory/Smoory.xcodeproj -scheme Smoory -configuration Debug build -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD " | head -10`
- Relaunch: `osascript -e 'quit app "Smoory"'; sleep 1; open /Users/alex/Library/Developer/Xcode/DerivedData/Smoory-awmhbyagcsebmraomliojfvpalyb/Build/Products/Debug/Smoory.app`
- After all commits, delete this file (`docs/UI_FIXES_PLAN.md`) — it's working notes, not a permanent spec doc.
- The user said "plan to fix all of them. when ready I'll compact and you continue". So: produce this plan, stop. After `/compact` and a "continue" from the user, start at Commit 1.
- CLAUDE.md rule reminder: any architectural decision not in the spec → propose + write to DECISIONS.md before implementing. F-1 (FeedItem.stateRaw) and F-23 (ErrorBus) qualify; surface a brief decision-line in the commit message and update DECISIONS.md inline.
