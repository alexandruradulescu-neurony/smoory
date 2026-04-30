# Phase 3 implementation notes

Working notes for Phase 3 (daily presence). Distinct from the spec — these are decisions and gaps deferred from earlier phases that Phase 3 must resolve before its work begins.

---

## Open gap from Phase 2 — Surface actions do not produce hema turn entries

**Decided in milestone 2.2.5c (2026-04-30).**

Spec ARCHITECTURE.md line 189 (Todos surface section) states:

> Both surfaces write to the same SwiftData store and produce the same hema turn entries. Neither path is "more real."

In milestone 2.2.5c we deferred the hema-turn part of that statement. Surface-driven actions (checkbox tap, swipe complete/defer/delete, detail view edits, quick-add, add-subtask, detail-view delete, undo) **do not currently write any hema turn**. They mutate the SwiftData store only.

The SwiftData store remains the single source of truth, so chat memory stays consistent at the data layer — Claude calling `get_open_todos` always sees the latest state. The gap is at the conversational memory layer: hema's `memory_turns` table never sees "user did X via the surface."

### What Phase 3 must decide

Phase 3.4 introduces week-review pattern observation. That feature reasons over the user's recent activity to surface patterns ("you've deferred 5 things this week", "Tuesday's todos always slip to Wednesday"). It needs an activity log.

Two paths:

1. **Reason over SwiftData timestamps directly.** `Todo.updatedAt`, `completedAt`, `deferralCount`, `deferredFrom`, `archivedAt`, the `[Deferred YYYY-MMM-DD: <reason>]` lines we append to notes — all already present in the store. Pattern observation queries the store, no hema turns needed.

2. **Add surface-turn writes.** Each surface action calls a `recordSurfaceTurn(content: String)` helper that writes to hema. Costs an embedding per action (Voyage call, ~30ms + cents). Keeps the spec's "same hema turn entries" claim literally true.

### Recommendation when Phase 3.4 starts

Default to option 1 unless option 2 surfaces a use case that pure SwiftData queries can't serve. The ergonomic argument for option 2 (uniform retrieval) is real but has a per-action cost that compounds at scale. SwiftData querying is free.

### What absolutely must not happen

This gap must not be silently lost. If Phase 3.4 lands without a reasoned choice between the two options, week-review pattern observation will produce inconsistent or incomplete results. Pick a path before building 3.4.

---

## Open gap from Phase 2 — Memory inspection has no pagination

**Decided in milestone 2.3 (2026-04-30).**

Memory inspection has hard 500-row limit per query, no pagination. Personal-scale memory grows slowly; revisit if hema accumulates >1k facts or >5k turns. Pagination is straightforward (offset is already a parameter on hema methods); UI work is the addition.

---

## Open gap from Phase 2 — Skipped onboarding has no recovery

**Decided in milestone 2.5 (2026-04-30).**

Onboarding 'Skip for now' is one-shot in v1 — user can't trigger it again from anywhere in the product. If users who skip later want to onboard properly, they'd need a Settings option to reset OnboardingState to .notStarted. Implement after first round of usage tells us if anyone actually skips and regrets it.

---

## Open gap from Phase 2 — Availability candidates not proactive

**Decided in milestone 2.4 (2026-04-30).**

Availability candidates currently go to the queue like any other candidate. Spec describes immediate proactive proposals (defer todos, decline meetings, set OOO) when the user states an availability change like 'I'll be off Tuesday'. Implement when first round of usage tells us whether the queue-and-confirm flow feels too slow for this specific case.

Stopgap acceptance behavior (2.4): availability candidates are written as semantic facts with tag `["availability"]` and the user-stated end date as `expiresAt`. There is no `Availability` or `OffPeriod` entity yet — `Schedule` is for repeating brief/review schedules and is the wrong fit. Phase 3 should decide: introduce `OffPeriod`, reuse `Schedule` with a kind extension, or keep facts-as-availability and read them via tag query when proactive proposals run.

---
