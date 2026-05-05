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

## ~~Open gap from Phase 2 — Availability candidates not proactive~~ — RESOLVED in 4.9

**Decided in milestone 2.4 (2026-04-30); resolved in milestone 4.9 (2026-05-04).**

Resolution: 4.9 introduced the `OffPeriod` SwiftData entity (kept as a separate entity rather than a `Schedule` extension), rewired `CandidateAcceptor.availability` to insert OffPeriod rows instead of tag-availability facts, and added `OffPeriodProposalGenerator` to surface conflicting todos as feed cards (via `FeedItemKind.offPeriodConflict`). See DECISIONS.md §4.9.

Calendar conflict surfacing is still partial — 4.9 surfaces nothing on the calendar side because calendar write is v2+. When calendar write lands, the generator's TODO at the bottom of `proposeConflicts` becomes a real branch.

Pre-4.9 stopgap availability facts (tag `["availability"]`) remain in hema unchanged; no migration ran. New writes route through `OffPeriod` only.

---

## Open gap from milestone 3.2 — Day review opener is static, not LLM-generated

**Decided in milestone 3.2 (2026-04-30).**

The day-review session opens with a randomly-picked line from a small static set ("How did today go?", "What stood out today?", "How are you feeling about today?", "Anything you want to capture from today?"). AI_PROMPTS.md §5 specifies a richer opener: claude-sonnet-4-6 generates an opener seeded with today's completed/slipped/calendar/goal data, surfaces 1–2 specific things, and invites a short reflection.

3.2 ships the static set per the milestone prompt. The LLM-generated opener is deferred until we've observed real day reviews for a week and know whether the static set is good enough or whether the concrete-acknowledgement requirement is load-bearing for engagement.

**When to revisit:** if users (the dev) report the opener feels generic or fails to draw out reflection, schedule a "review opener generator" milestone that wires `claude-sonnet-4-6` (or active provider's heavy tier) into `DayReviewViewModel.startIfNeeded()` with the inputs listed in AI_PROMPTS.md §5. The static-set call site is `DayReviewPrompts.randomOpener()` — single-call replacement.

---

## Cosmetic patch from milestone 4.0 — `<current_datetime>` timezone format

**Captured during milestone 4.0 (2026-05-04).**

The `<current_datetime>` block assembled by `Orchestrator.assemblePrompt()` currently formats the timezone as an abbreviation (e.g., `EEST`) plus the IANA identifier in parentheses (`Europe/Bucharest`). Runtime example:

```
<current_datetime>
Today is Monday, May 4, 2026. Local time is 18:16 EEST (Europe/Bucharest). Resolve relative dates ("today", "tomorrow", "next Monday") and relative times ("in an hour", "tonight") against this.
</current_datetime>
```

LLMs sometimes misread three- and four-letter timezone abbreviations (`EEST`, `EDT`, `BST`, etc.) — they're ambiguous (e.g., `BST` could be British Summer Time or Bangladesh Standard Time) and the model may infer the wrong UTC offset.

**Consider switching** to a UTC-offset form: `Monday, 2026-05-04 18:16 UTC+03:00 (Bucharest)`. UTC offsets are unambiguous and easier for the model to arithmetic on.

**Why deferred:** cosmetic, not urgent. The 4.0 milestone explicitly preserved the existing format because the time-reasoning rules read fine with weekday + full date + local time + abbreviation, and changing the format would have invalidated the test scenarios run in 4.0.

**Where to change when picked up:** `Orchestrator.assemblePrompt()` (currently `Smoory/Smoory/Pipeline/Orchestrator.swift` ~line 221). Replace the `dateString` / `timeString` / `tzAbbrev` formatters with a single ISO-style date + 24h time + `UTC±HH:MM` offset, drop the IANA identifier or move it to a parenthetical city name. After change, re-run the 4.0 voice/time scenarios to confirm the new format doesn't regress time reasoning.

---
