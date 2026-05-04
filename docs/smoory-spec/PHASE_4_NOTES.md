# Phase 4 — usage-period notes

Observations from real Phase 1 usage that should shape Phase 4's email
work. These are not yet promoted into BEHAVIORS.md or other spec
documents; they live here until Phase 4 design starts.

---

## "Today's email activity" feed item

**Source:** noticed Phase 1 usage, 2026-04-29.

**Idea:** A daily end-of-day feed item summarizing what Smoory's email
triage actually did that day.

Example shape:
> 📧 Today's email activity
> - 47 emails arrived
> - 38 classified as noise (silently dropped)
> - 5 receipts logged (searchable, no surfacing)
> - 4 surfaced as feed items (acted on or pending)
> - 0 operational alerts
>
> [Show breakdown] [Review dropped]

**Why it earns its place:**
The feed is currently designed to surface only what warrants attention.
That's right for the workflow but creates a trust gap — the user can't
easily verify the noise filter isn't eating real correspondence.

A daily summary item solves the trust gap without rebuilding Mail's
inbox in Smoory:
- Tiny footprint in the feed (one item, end of day)
- Quantifies what triage did (numbers create accountability)
- Provides an entry point to "review dropped" for periodic audit
- Becomes obviously unnecessary over time as triage proves itself —
  user can dismiss/disable it once trust is established

**When in Phase 4:**
Likely after the basic triage pipeline is working but before the full
correspondence enrichment lands. It's a natural complement to the
triage classifier — easy to build once the classifier is firing and
counters are accumulating.

**Open questions:**
- Daily, or also weekly with deeper stats?
- Integrated into the day review flow, or a separate feed item?
- Threshold to suppress on quiet days (no email = no item)?

---

## "Show me email" tool callable from chat

**Source:** noticed Phase 1 usage, 2026-04-29 (extension of the
"calendar-aware chat" gap that motivated Phase 2 tool-calling).

**Idea:** Email retrieval through conversational chat, not through a
dedicated email view. Lean into Smoory's "conversation as input" principle.

Example flows:
> User: "what came in from Maria last week?"
> Smoory: [searches Mail, returns 3 matching messages with context]
>         "Three emails from Maria in the past 7 days. The Apollo
>         status update on Tuesday, a quick scheduling note Thursday,
>         and Friday's deadline-shift conversation that's still open
>         in your feed. Want me to surface any of them?"

> User: "anything from accounts@stripe.com this month?"
> Smoory: [searches Mail receipts log, returns matches]
>         "Six Stripe receipts this month, totaling €342. Three for
>         the business account, three for personal. Want a breakdown?"

**Why it earns its place:**
- Avoids building a parallel inbox UI in Smoory.
- Uses tool-calling (Phase 2 infrastructure) for what tool-calling is
  for — letting the user ask natural-language questions over their data.
- Keeps Apple Mail as the inbox; Smoory becomes the lens through
  which the inbox is *queried*.
- Naturally extends to "find me that email about X from a few weeks
  ago" — the email-equivalent of the "who was that guy from..."
  retrieval question already in BEHAVIORS.md.

**Tools this implies (extending TOOLS.md):**
- `search_email` — query Mail by sender, date range, subject keywords,
  body keywords, attachment presence. Returns matched email metadata.
- `read_email_body` — get the full body of a specific message by ID.
- `summarize_emails` — given a set of message IDs, generate a short
  summary across them.

**Confirmation tier:** all silent (read-only). They become tier-1
when extended to actions like "archive these emails" — but those
already exist in TOOLS.md.

**Memory implications:**
Search results don't auto-write to memory; the user's question and
Smoory's reply do (as normal chat turns). If a search reveals
something noteworthy ("you've gotten 3 separate quotes for X this
month"), the structuring layer can propose a semantic fact.

**When in Phase 4:**
After triage and correspondence enrichment are working. The search
tools are easier to build than the triage classifier (no AI judgment
needed for retrieval — just Mail-DB queries) but more useful once
the user has months of triage history to search across.

**Open questions:**
- How does search interact with hema's vector memory of past
  conversations *about* emails? When the user asks "what did Maria
  send last week," do we search Mail directly, or also search hema
  for past Smoory annotations of Maria's emails?
- Performance — Mail's local DB is fast for metadata queries, slower
  for full-body searches across years of mail. May need pagination
  or recency filters by default.

---

## toneObservation candidate destination

**Source:** milestone 2.4 (2026-04-30).

toneObservation candidates currently land as facts tagged 'tone'. When email drafting lands in Phase 4, decide: match to existing Person records and update ToneProfile, or drop toneObservation as a candidate type entirely. Workaround should not become permanent behavior silently.

---

## Adding more notes

When new observations from usage point toward Phase 4 changes, append
sections here using the same shape:

- **Source:** when/why you noticed it
- **Idea:** the proposed addition
- **Why it earns its place:** the design rationale
- **When in Phase 4:** ordering relative to other Phase 4 work
- **Open questions:** anything unresolved

These notes get promoted into BEHAVIORS.md / TOOLS.md / AI_PROMPTS.md
during Phase 4 design, not before. Keeping them isolated here means
the formal spec stays clean while ideas accumulate.

---

## Deferred: TodosService refactor (post-4.1)

4.1 instrumented 8 todo mutation sites with `TodosSnapshotWriter.writeFromStore()` calls. A full `TodosService` to centralize them was out of scope for 4.1. When cross-cutting todo behavior is needed (auto-archive, completion telemetry, structuring layer integration), refactor to `TodosService` and collapse the helper calls to one site. Until then, the helper pattern is the accepted architecture.
