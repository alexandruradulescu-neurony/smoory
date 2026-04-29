# Memory (Hema)

Smoory's long-term memory system. Named hema. Adapted from the HEMA architecture (compact memory + vector memory) but ported to Swift, integrated with structured state, and extended with semantic facts.

This document specifies how hema works inside Smoory specifically. The original HEMA was designed for maintaining coherence within long single LLM conversations; here, hema's job is broader — it's the cross-session memory that makes Smoory feel like *yours* over months and years.

---

## What hema stores

Three distinct components, each with a specific purpose. All three are queryable independently and combined during context assembly.

### 1. Compact Memory

A small set of rolling natural-language summaries. Written by Claude, regenerated on cadence. Cheap to include in every prompt.

**Tiers:**
- **Overall summary** — one paragraph (~150 words) about the user as Smoory understands them today. Regenerated weekly during the week review.
- **Recent summary** — one paragraph (~200 words) covering the last 7 days. Regenerated daily after the day review.
- **Today's running summary** — one paragraph (~100 words) covering today's significant events. Regenerated at end of day or when the conversation accumulates enough turns to warrant refresh.

**Storage:** SwiftData entity `CompactMemory` with a `kind` enum and a `body` text field, one row per active tier, with a history of past versions kept for inspection.

### 2. Vector Memory

Every significant chat turn (user and assistant) is embedded into a vector and indexed in `sqlite-vec`. Used for semantic retrieval: "find past conversation moments relevant to the current input."

**What gets embedded:**
- All user chat messages
- All assistant chat replies
- Day-review and week-review reflections
- Email annotations Smoory generated (so Smoory can later recall its own past reasoning about a thread or person)

**What does NOT get embedded:**
- Tool call payloads (just the human-meaningful text around them)
- System prompts
- Triage classifier inputs (high volume, low value)
- Receipts, transactional confirmations, or any content classified as `noise` by triage

**Storage:** SQLite table `memory_turns` with columns: `id`, `created_at`, `role` (user/assistant), `content`, `vector` (BLOB via sqlite-vec), `chat_session_id`, `metadata_json`.

**Embeddings:**
Apple's `NLEmbedding.sentenceEmbedding(for: .english)` is the v1 default — on-device, free, 300-dimensional. Quality is sufficient for personal-scale retrieval. Swappable to higher-quality embeddings (Voyage, OpenAI) if retrieval quality issues emerge.

### 3. Semantic Facts

Discrete, structured records of things Smoory has learned. Each fact is a self-contained unit: a sentence-length statement plus metadata.

**Examples:**
- "User is off May 1–2 for national holiday."
- "User prefers deep work in mornings, meetings after lunch."
- "User's business uses Stripe for billing."
- "Maria at Acme is the project lead for the Apollo migration."
- "User mentioned wanting to read 50 pages/day."
- "User declined the offer from Bolt because timeline didn't fit."

**Storage:** SQLite table `semantic_facts` with columns: `id`, `created_at`, `body` (the fact statement), `vector` (BLOB), `tags` (JSON array), `entities_referenced` (JSON: lists of person IDs, role IDs, etc.), `confidence` (Double), `provenance_json`, `expires_at` (nullable), `superseded_by` (nullable, for facts that have been replaced).

**Why both vectors AND structured fields?**
- Vectors enable fuzzy semantic retrieval ("what does Smoory know about Lisbon?")
- Structured fields enable deterministic queries ("all facts about Person X", "all facts tagged 'availability' that haven't expired")
Both modes are used — different queries call different paths.

**Time-bounded facts:**
Facts can have an `expires_at` — e.g. "user is off May 1–2" expires May 3. Expired facts are not retrieved into active context but remain searchable for historical questions ("when was I last on holiday?").

**Superseding:**
When a new fact contradicts an existing one ("user changed jobs from Acme to Bolt"), the old fact gets a `superseded_by` pointer to the new one. The chain is preserved for audit, and only the latest version is retrieved into active context.

---

## How hema retrieves

Retrieval happens during the enrichment stage of the loop. The orchestrator constructs a query, calls hema, gets back ranked context items, and packs them into the Claude call.

**Standard retrieval call:**

```
hema.retrieve(
  query: String,                  // the text to retrieve against
  k: Int = 8,                     // number of vector hits
  factTags: [String]? = nil,      // optional: filter facts by tag
  entities: [EntityRef]? = nil,   // optional: filter to facts about specific entities
  timeRange: DateRange? = nil,    // optional: scope by time
  excludeExpired: Bool = true
) -> RetrievalResult
```

**Returns:**
```
struct RetrievalResult {
  compactSummaries: [CompactMemory]   // always include all active tiers
  turns: [MemoryTurn]                 // top-k from vector search over turns
  facts: [SemanticFact]               // top-k from vector search + tag/entity filters
  scores: [UUID: Double]              // for debugging, IDs to similarity scores
}
```

**Fusion strategy:**
Compact summaries are always included. Vector hits over turns and facts are independently retrieved and merged. The orchestrator decides what subset goes into the Claude call based on token budget.

**Token budget defaults:**
- Compact summaries: ~600 tokens (always included)
- Top facts: ~600 tokens (5–8 facts typical)
- Top turns: ~800 tokens (3–5 turn excerpts typical)
- Total memory context: ~2000 tokens

The remainder of the context window is for the active payload (user message, email body, etc.) and the structured state (open todos, calendar window, etc.).

---

## How hema writes

Writes happen in three ways:

### 1. Automatic from chat
Every chat turn is embedded and stored as a `MemoryTurn`. No user confirmation needed.

### 2. Automatic from structuring layer
The structuring layer that runs after every chat turn produces candidate semantic facts. Confidence-thresholded:
- High-confidence facts (e.g. "user said they're off Friday") → write immediately, no user prompt
- Medium-confidence facts → propose in feed as memory_candidate items, user confirms
- Low-confidence facts → discarded

### 3. Automatic from reviews
Day reviews and week reviews produce structured reflections that become semantic facts:
- "User reported feeling overwhelmed on Tuesday."
- "User completed 80% of morning todos this week, 40% of afternoon todos."
- "User skipped reading goal three days in a row this week."

These are written silently after the review.

**Memory writes are silent.** No interruption. But every write is visible in the memory inspection view.

---

## Memory inspection view

A first-class surface in the app. Users can:

- **Browse all facts**, paginated, filterable by tag, entity, date range, source.
- **Read each fact** with its body, tags, provenance, confidence score, age, expiry.
- **Edit a fact** — change the wording, change tags, set expiry, mark as low-confidence.
- **Delete a fact** — hard delete or supersede.
- **Ask "why do you think this?"** — opens the fact's provenance: which conversation turn(s) produced this fact, from which review or chat session, on what date.
- **Browse turns** — search past conversation turns by content or by similarity to a query.
- **Browse compact summaries** — see current and historical summaries for each tier.

This view is the trust mechanism. Memory writes happen silently; the user's recourse is full inspectability.

---

## Compact memory regeneration

Compact summaries are LLM-generated by Claude. Each tier has its own regeneration trigger and prompt.

### Today's running summary
- **Trigger:** at the end of each chat session, OR when the day's accumulated turns cross a threshold (e.g. 30 turns), OR at end of day before the day review.
- **Input:** today's `MemoryTurn` records, plus today's calendar events and completed todos.
- **Output:** ~100 word paragraph.
- **Use:** included in every Claude call as immediate context.

### Recent summary (7-day rolling)
- **Trigger:** during the day review.
- **Input:** the previous recent summary + today's running summary + the last 7 days of high-salience facts.
- **Output:** ~200 word paragraph.
- **Use:** included in every Claude call. Is the medium-term context.

### Overall summary
- **Trigger:** during the week review.
- **Input:** previous overall summary + the week's recent summary + high-salience facts from the week (especially newly-confirmed goals, role changes, big project shifts).
- **Output:** ~150 word paragraph stating the user's situation as Smoory understands it now.
- **Use:** included in every Claude call as the long-term context.

**Regeneration prompt sketches** are in `AI_PROMPTS.md`.

---

## Forgetting

Hema does not currently forget arbitrarily. Three explicit deletion mechanisms:

1. **Expiry** — time-bounded facts naturally expire and stop being retrieved into active context (still searchable).
2. **Superseding** — newer facts replace older ones; old fact stays as audit trail.
3. **User deletion** — user explicitly deletes from the inspection view.

A future enhancement (post-v1) would be **age-weighted relevance decay** in vector retrieval — older turns get a lower score multiplier — to keep retrieval focused on recent context. v1 keeps it simple: pure cosine similarity, no decay.

A second future enhancement: **semantic forgetting**, where Smoory periodically proposes pruning low-value facts ("Want me to forget that you once mentioned liking a TV show in passing?"). v1 keeps everything.

---

## Provenance

Every semantic fact carries provenance. Stored as JSON in the `provenance_json` column.

**Provenance shape:**
```
{
  "source_kind": "chat_turn" | "day_review" | "week_review" | "structuring_layer" | "email_annotation" | "manual",
  "source_ids": [UUID, ...],
  "source_session_id": UUID,
  "extracted_at": ISO8601,
  "extracting_model": "claude-haiku-4-5",
  "confidence": Double,
  "user_confirmed": Bool,
  "user_confirmed_at": ISO8601 | null
}
```

The "why do you think this?" view in the memory inspection surface renders this provenance as a human-readable explanation.

---

## Schema (SQLite)

Hema uses SQLite directly via the `sqlite-vec` extension, separate from SwiftData. Reason: SwiftData and sqlite-vec don't compose cleanly, and hema benefits from explicit SQL for vector queries.

```sql
-- Compact summaries
CREATE TABLE compact_memory (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,                    -- 'overall' | 'recent' | 'today'
  body TEXT NOT NULL,
  word_count INT,
  generated_at TEXT NOT NULL,
  superseded_at TEXT,                    -- NULL if currently active
  generating_model TEXT
);

-- Conversational turns (vector + content)
CREATE TABLE memory_turns (
  id TEXT PRIMARY KEY,
  created_at TEXT NOT NULL,
  chat_session_id TEXT NOT NULL,
  role TEXT NOT NULL,                    -- 'user' | 'assistant'
  content TEXT NOT NULL,
  metadata_json TEXT,
  vector BLOB                            -- managed by sqlite-vec
);
CREATE VIRTUAL TABLE memory_turns_vec USING vec0(
  embedding float[300]
);

-- Semantic facts
CREATE TABLE semantic_facts (
  id TEXT PRIMARY KEY,
  body TEXT NOT NULL,
  tags_json TEXT,
  entities_json TEXT,                    -- list of entity references
  confidence REAL,
  user_confirmed INT NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  expires_at TEXT,
  superseded_by TEXT,                    -- foreign key to another fact id
  provenance_json TEXT,
  vector BLOB
);
CREATE VIRTUAL TABLE semantic_facts_vec USING vec0(
  embedding float[300]
);

-- Indexes
CREATE INDEX idx_turns_session ON memory_turns(chat_session_id);
CREATE INDEX idx_turns_created ON memory_turns(created_at);
CREATE INDEX idx_facts_created ON semantic_facts(created_at);
CREATE INDEX idx_facts_expires ON semantic_facts(expires_at);
```

---

## Privacy and what gets sent to Claude

When hema retrieves context for a Claude call, only the **subset relevant to the current task** is included. Not the full memory.

**Per-call filtering:**
- Drafting an email to Person X → include facts tagged `person:X`, the X-specific tone profile, and the relevant thread state. Do NOT include facts about unrelated people or topics.
- Morning brief → include the recent summary, today's calendar, open high-priority todos, active goals. Do NOT include unrelated past conversation turns.
- Generic chat reply → use top-k vector retrieval over the user's message; tightly bounded.

This filtering is the orchestrator's job. Each enrichment-call type has a context recipe specifying what to retrieve and what to exclude.

**Sensitive markers:**
The user can flag a memory fact as "private" — it will never be sent to Claude even if relevant. (Useful for things you'd like Smoory to remember but not actively reason about.) Implementation: add a `private` boolean to `semantic_facts`; retrieval skips private facts unless explicitly requested.

---

## Bootstrapping memory

When Smoory is first installed, hema is empty. The onboarding conversation populates the initial memory in real time:

- Every onboarding chat turn is embedded as a `MemoryTurn`.
- The structuring layer runs throughout, producing semantic fact candidates that the user confirms in real time (during onboarding, candidates are surfaced in-line rather than batched).
- After onboarding, an initial overall summary is generated and stored as the first `CompactMemory` of kind `overall`.

By the end of onboarding, hema has 30–60 confirmed semantic facts and the user's first compact summary. Smoory can already speak about the user with continuity in the next session.

---

## Mapping to the HEMA paper

Smoory's hema is an *adaptation* of the HEMA architecture (Ahn, K. *HEMA: A Hippocampus-Inspired Extended Memory Architecture for Long-Context AI Conversations*, 3blocks.ai). The core duality — a compact memory carrying narrative continuity and a vector memory for episodic recall — is preserved. The implementation diverges in several ways tailored to a personal-assistant deployment rather than a research benchmark on long-form dialogues.

### What's preserved (faithful to HEMA)

- Two-component design: compact memory (always-visible summary) + vector memory (on-demand retrieval)
- Cosine similarity retrieval over chunk embeddings
- Prompt composition pattern: system guidelines + compact summary + retrieved chunks + recent dialogue tail
- Prompt budget discipline (memory context bounded to leave room for the active payload)

### What's adapted

| HEMA paper | Smoory's hema | Reason |
|---|---|---|
| Single one-sentence Compact Memory summary, regenerated continuously | Three tiered summaries: today (~100 words), recent 7-day (~200 words), overall (~150 words) | A personal assistant benefits from temporal layering — today's shape, the week, the user's enduring situation — that a single sentence can't carry. |
| Summary-of-Summaries every 100 turns to prevent drift | Cadence-driven regeneration: today rebuilt at end of day, recent rebuilt during day review, overall rebuilt during week review | Smoory's natural daily/weekly rituals are the right regeneration triggers. Turn-count-based cadence doesn't fit a system where activity volume varies wildly day-to-day. |
| `text-embedding-3-small` (1536-dim) via OpenAI | Apple `NLEmbedding` (300-dim) on-device | Privacy, no extra API key, sufficient quality at personal scale. Swap path documented in DECISIONS.md. |
| FAISS IVF-4096 + OPQ-16 | `sqlite-vec` extension to embedded SQLite | Single-file embedded deployment; no separate process. Sufficient at personal scale (<100k vectors). FAISS-equivalent performance available on Postgres + pgvector if migration ever happens. |
| Distil-PEGASUS-dialogue summarizer (≤60 tokens) | Claude Sonnet for summary regeneration | Already have Sonnet in the loop; avoiding a second model deployment. The paper's choice was a research-budget concern. |
| Semantic forgetting via age-weighted salience formula, pruning lowest 0.5% every 100 turns | Not implemented in v1; deferred | At personal scale (single user, ~10k items per year), storage isn't a v1 concern. The paper's formula `w_i = λe^(-γ(t-i)) + β(1-δ_i)` is the planned implementation when forgetting is added. |
| Frozen 6B-parameter transformer | Anthropic Claude API (multiple models routed by call type) | Different deployment model. The paper demonstrates the architecture works with a small frozen LLM; using a stronger hosted model relaxes context budget pressure and makes pattern observation calls (Opus) feasible. |

### What's added (Smoory-specific)

- **Semantic facts** as a third memory tier with structured metadata, expiry, supersession, and provenance. The paper has only compact summary + vector chunks; personal-assistant use cases need structured retrievable facts (availability windows, person tone profiles, infrastructure records, holiday flags) that conversational chunks alone can't represent.
- **Memory inspection view** as a first-class user surface. The paper doesn't address user-facing trust mechanics; for a research system the dual memory is internal.
- **Per-call privacy filtering**. Only the subset of memory relevant to the current task is included in any API call. The paper doesn't separate per-call slicing because its setting is research benchmarks, not external-API deployment.
- **Provenance tracking** on every fact (source kind, source IDs, extracting model, confidence, user-confirmed flag).
- **Confidence-thresholded silent writes**: high-confidence semantic facts written without prompting; medium-confidence surfaced as candidates; low-confidence discarded.
- **Private-fact flag** that excludes a fact from being sent to the LLM API even if otherwise relevant.

### What might come back from the paper post-v1

- Semantic forgetting using the paper's salience formula, once memory bloat becomes an actual concern
- Summary-of-summaries hierarchy if compact memories themselves grow too long over years of use
- An empirical comparison of Smoory's three-tier compact memory vs. HEMA's single-sentence approach to validate that the temporal layering is worth the added complexity

The HEMA paper is the right citation for the lineage. Smoory is not a faithful HEMA implementation; it's a Smoory-specific memory layer that derives from HEMA's core insight (compact + vector duality) and extends it for the personal-assistant context.

---

Read **BEHAVIORS.md** next.
