# Tools

The catalog of tools Claude can call when orchestrating actions. Each tool is implemented as a Swift function that the orchestrator routes from the AI's tool-call output.

Tools are grouped by domain. Each tool entry includes:
- **Name** (used in the tool-calling schema)
- **Purpose**
- **Confirmation tier** (tier1_quick / tier2_review / tier3_dialog / silent)
- **Input parameters** (JSON schema sketch)
- **Returns**
- **Side effects**

Tools marked `silent` execute without user confirmation. Tools marked `tier1`/`tier2`/`tier3` produce a feed item or chat card and execute only after user approval.

When sending tools to Claude in a call, only include the subset relevant to the current loop type (e.g., email-annotation calls don't get habit tools). Keeping the tool surface narrow per call improves model focus and reduces drift.

---

## Read tools (silent — no user action required)

These read state. Always silent. Always available.

### `get_open_todos`
**Purpose:** Read currently open todos with optional filters.
**Tier:** silent
**Inputs:**
```
{
  "role": "string?",            // optional role slug to filter
  "project_id": "string?",      // optional project filter
  "thread_id": "string?",       // optional thread filter
  "due_before": "ISO date?",
  "priority_min": "low|normal|high|urgent",
  "limit": "int (default 20)"
}
```
**Returns:** array of `Todo` objects.

### `get_calendar_window`
**Purpose:** Read calendar events in a time range.
**Tier:** silent
**Inputs:**
```
{
  "start": "ISO date",
  "end": "ISO date",
  "calendars": ["string"]?   // optional: specific calendars
}
```
**Returns:** array of `CalendarEvent` (title, start, end, location, attendees).

### `get_active_goals`
**Purpose:** Read currently active goals.
**Tier:** silent
**Inputs:** `{"role": "string?"}`
**Returns:** array of `Goal` objects with current progress data.

### `get_active_threads`
**Purpose:** List active threads.
**Tier:** silent
**Inputs:** `{"role": "string?", "include_awaiting": "bool"}`
**Returns:** array of `Thread` objects.

### `get_thread_state`
**Purpose:** Get full state of a single thread (events, emails, todos, summary).
**Tier:** silent
**Inputs:** `{"thread_id": "string"}`
**Returns:** `ThreadState` with summary, list of emails, list of todos, list of events.

### `find_person`
**Purpose:** Look up a person by name, email, or fuzzy description.
**Tier:** silent
**Inputs:**
```
{
  "query": "string",                  // name fragment, email, or fuzzy description
  "use_semantic_search": "bool"       // if true, use hema vector retrieval over Person notes
}
```
**Returns:** array of candidate `Person` objects with confidence scores.

### `get_person_record`
**Purpose:** Get full Person record by ID.
**Tier:** silent
**Inputs:** `{"person_id": "string"}`
**Returns:** `Person` object including tone profile.

### `get_recent_email_with_person`
**Purpose:** Pull recent email exchange history with a person (read-only, from Mail DB).
**Tier:** silent
**Inputs:** `{"person_id": "string", "limit": "int (default 5)"}`
**Returns:** array of email metadata + body excerpts.

### `get_infrastructure`
**Purpose:** Read infrastructure records.
**Tier:** silent
**Inputs:** `{"category": "string?", "role": "string?"}`
**Returns:** array of `Infrastructure` objects.

### `get_profile`
**Purpose:** Read the user's profile blob.
**Tier:** silent
**Inputs:** none
**Returns:** `Profile` object.

### `retrieve_memory`
**Purpose:** Hema retrieval. The orchestrator usually does this in context assembly, but Claude can also call it directly mid-conversation if it needs to dig deeper.
**Tier:** silent
**Inputs:**
```
{
  "query": "string",
  "k": "int (default 8)",
  "fact_tags": ["string"]?,
  "entities": ["EntityRef"]?,
  "time_range": "DateRange?",
  "include_expired": "bool"
}
```
**Returns:** `RetrievalResult` (compact summaries, top facts, top turns).

---

## Write tools — Todos

### `create_todo`
**Purpose:** Create a new todo.
**Tier:** tier1_quick
**Inputs:**
```
{
  "title": "string",
  "notes": "string?",
  "due_date": "ISO date?",
  "priority": "low|normal|high|urgent",
  "role_slug": "string?",
  "project_id": "string?",
  "thread_id": "string?",
  "related_people": ["string"]?,
  "source": "ai_proposal"           // always set to ai_proposal for AI-created
}
```
**Returns:** the created `Todo` (or pending proposal ID until user confirms).

### `complete_todo`
**Purpose:** Mark a todo as completed.
**Tier:** tier1_quick
**Inputs:** `{"todo_id": "string"}`
**Returns:** updated `Todo`.
Works on both top-level todos and subtasks — they share the schema.

### `update_todo`
**Purpose:** Modify an existing todo.
**Tier:** tier1_quick
**Inputs:**
```
{
  "todo_id": "string",
  "title": "string?",
  "notes": "string?",
  "due_date": "ISO date?",
  "priority": "...?",
  "role_slug": "string?",
  "project_id": "string?",
  "thread_id": "string?"
}
```
**Returns:** updated `Todo`.
Works on both top-level todos and subtasks — they share the schema.

### `defer_todo`
**Purpose:** Push the due date out and capture a reason.
**Tier:** tier1_quick
**Inputs:** `{"todo_id": "string", "new_due_date": "ISO date", "reason": "string?"}`
**Returns:** updated `Todo`.
Works on both top-level todos and subtasks — they share the schema.

### `delete_todo`
**Purpose:** Soft-delete (archive) a todo.
**Tier:** tier1_quick
**Inputs:** `{"todo_id": "string"}`
**Returns:** confirmation.
Works on both top-level todos and subtasks — they share the schema.

### `create_subtask`
**Purpose:** Add a subtask to an existing Todo. Subtasks are full Todos with their `parentTodo` set; they share all the affordances of regular todos (due dates, priority, completion).
**Tier:** tier1_quick
**Inputs:**
```
{
  "parent_todo_id": "string",      // required — UUID of the parent Todo
  "title": "string",               // required
  "due_date": "ISO 8601 date?",    // optional
  "priority": "low|normal|high|urgent",  // optional, default normal
  "role_slug": "string?"           // optional; subtasks inherit parent's role if not specified
}
```
**Returns:** the created subtask Todo.
**Notes:**
- Fails with a tool error if `parent_todo_id` does not exist OR if the referenced Todo itself has `parentTodo != nil` (no second-level nesting).
- If `role_slug` is omitted, the subtask inherits its parent's role.
- The parent's fractional progress display updates automatically on the next render (computed from subtasks).

---

## Write tools — Goals

### `create_goal`
**Purpose:** Create a new goal.
**Tier:** tier1_quick
**Inputs:**
```
{
  "title": "string",
  "description": "string?",
  "role_slug": "string?",
  "goal_type": "tracked|reflective|both",
  "tracked_signal": {                // present if goal_type includes tracked
    "metric": "string",
    "target": "number",
    "cadence": "daily|weekly|monthly",
    "unit": "string"
  }?,
  "reflective_cadence": {            // present if goal_type includes reflective
    "frequency": "weekly|biweekly|monthly|quarterly",
    "preferred_day": "string?"
  }?,
  "target_date": "ISO date?"
}
```
**Returns:** the created `Goal` (or pending proposal until confirmed).

### `update_goal_status`
**Purpose:** Change a goal's status (active, paused, achieved, dropped).
**Tier:** tier1_quick
**Inputs:** `{"goal_id": "string", "status": "active|paused|achieved|dropped", "reason": "string?"}`
**Returns:** updated `Goal`.

### `update_goal`
**Purpose:** General goal modification.
**Tier:** tier1_quick (tier2 if changing tracked signal substantially)
**Inputs:** similar shape to create_goal but with `goal_id`.

### `log_goal_progress`
**Purpose:** Log progress against a tracked goal (e.g. "logged 25 minutes of reading").
**Tier:** tier1_quick
**Inputs:**
```
{
  "goal_id": "string",
  "value": "number",
  "logged_at": "ISO date?",          // default now
  "note": "string?"
}
```
**Returns:** updated progress record.

---

## Write tools — Projects

### `create_project`
**Purpose:** Create a new project.
**Tier:** tier1_quick
**Inputs:**
```
{
  "title": "string",
  "description": "string?",
  "role_slug": "string?",
  "parent_goal_id": "string?",
  "target_date": "ISO date?"
}
```

### `update_project_status`
**Purpose:** Change a project's status.
**Tier:** tier1_quick
**Inputs:** `{"project_id": "string", "status": "planning|active|paused|completed|abandoned"}`

### `update_project`
**Purpose:** General modification.
**Tier:** tier1_quick

---

## Write tools — Threads

### `create_thread`
**Purpose:** Create a thread, manually or as a confirmed inference.
**Tier:** tier1_quick
**Inputs:**
```
{
  "title": "string",
  "summary": "string?",
  "role_slug": "string?",
  "related_project_id": "string?",
  "initial_email_ids": ["string"]?,
  "initial_todo_ids": ["string"]?,
  "inferred": "bool"
}
```

### `attach_to_thread`
**Purpose:** Add an email, todo, or person to an existing thread.
**Tier:** tier1_quick
**Inputs:** `{"thread_id": "string", "attachment_kind": "email|todo|person", "attachment_id": "string"}`

### `update_thread_status`
**Purpose:** Change thread state.
**Tier:** tier1_quick
**Inputs:** `{"thread_id": "string", "status": "open|active|awaiting|closed", "closed_reason": "string?"}`

### `regenerate_thread_summary`
**Purpose:** Trigger a re-summarization of the thread (silent; happens after activity).
**Tier:** silent
**Inputs:** `{"thread_id": "string"}`

---

## Write tools — People

### `propose_person_record`
**Purpose:** Propose adding a new person Smoory has identified from email or chat.
**Tier:** tier1_quick (tier3_dialog for first-contact ambiguous cases)
**Inputs:**
```
{
  "display_name": "string",
  "primary_email": "string?",
  "company": "string?",
  "title": "string?",
  "relationship": "string?",
  "how_we_met": "string?",
  "notes": "string?",
  "tags": ["string"]?,
  "role_slugs": ["string"]?
}
```

### `update_person`
**Purpose:** Modify a person record.
**Tier:** tier1_quick (tier2 if changing primary email or company)
**Inputs:** `{"person_id": "string", ...fields...}`

### `apple_contacts_sync`
**Purpose:** Push identity fields to Apple Contacts.
**Tier:** tier2_review
**Inputs:** `{"person_id": "string", "fields_to_sync": ["name|email|phone|company|title"]}`
**Notes:** Always tier-2 because writing to Apple Contacts is visible across other apps.

---

## Write tools — Memory

### `write_memory_fact`
**Purpose:** Write a semantic fact to hema. High-confidence facts only.
**Tier:** silent (with full transparency in memory inspection view)
**Inputs:**
```
{
  "body": "string",
  "tags": ["string"],
  "entities_referenced": [{"type": "string", "id": "string"}]?,
  "confidence": "number",
  "expires_at": "ISO date?",
  "supersedes": "string?",                 // existing fact id this replaces
  "provenance": {
    "source_kind": "string",
    "source_ids": ["string"]?,
    "source_session_id": "string?"
  }
}
```
**Returns:** new fact ID.

### `propose_memory_candidate`
**Purpose:** For medium-confidence facts, propose as a candidate (surfaces in feed).
**Tier:** tier1_quick (the candidate proposal)
**Inputs:** same shape as `write_memory_fact` but produces a feed item rather than writing directly.

### `update_memory_fact`
**Purpose:** Edit an existing fact (e.g. correcting an inferred detail).
**Tier:** tier1_quick (or silent if confidence-driven internal correction)

### `expire_memory_fact`
**Purpose:** Mark a fact as expired ahead of its natural expiry.
**Tier:** silent

### `regenerate_compact_summary`
**Purpose:** Rebuild one of the compact memory tiers.
**Tier:** silent
**Inputs:** `{"kind": "today|recent|overall"}`

---

## Write tools — Email (Apple Mail integration)

### `mark_email_for_reply`
**Purpose:** Flag an email in Apple Mail (using a Mail label or VIP-style tag).
**Tier:** tier1_quick
**Inputs:** `{"message_id": "string"}`

### `archive_email`
**Purpose:** Archive in Apple Mail (moves to archive mailbox).
**Tier:** tier1_quick
**Inputs:** `{"message_id": "string"}`

### `flag_email`
**Purpose:** Apply a Mail flag (color or named).
**Tier:** tier1_quick
**Inputs:** `{"message_id": "string", "flag": "string"}`

### `draft_email`
**Purpose:** Create a draft email (does not send).
**Tier:** tier2_review
**Inputs:**
```
{
  "to": ["string"],
  "cc": ["string"]?,
  "bcc": ["string"]?,
  "subject": "string",
  "body": "string",
  "in_reply_to_message_id": "string?",
  "thread_id": "string?",
  "tone_used": "string?"
}
```
**Returns:** draft preview shown in feed/chat for user review.

### `send_email`
**Purpose:** Send a previously-drafted (and user-reviewed) email.
**Tier:** tier2_review (always — sending mail is never tier-1)
**Inputs:** `{"draft_id": "string"}`
**Notes:** This is invoked on user click of "Send" after they've reviewed the draft.

### `extract_calendar_invite`
**Purpose:** Parse a calendar invite email into a structured event proposal.
**Tier:** silent (parsing); the resulting calendar event creation is its own tier.

---

## Write tools — Calendar (v1 read-only; tier-2 in v2+)

### `create_calendar_event` (post-v1)
**Tier:** tier2_review
**Inputs:** standard event fields.

### `decline_calendar_event` (post-v1)
**Tier:** tier2_review

### `propose_time_block` (post-v1)
**Purpose:** Propose adding a "deep work block" or "reading session" to the calendar.
**Tier:** tier2_review

---

## Write tools — Capture

### `add_capture_item`
**Purpose:** Add an item to the capture inbox.
**Tier:** tier1_quick (or silent if user explicitly captured via hotkey)
**Inputs:**
```
{
  "kind": "text|url|file|image|voice_note|pdf",
  "content": "string?",
  "file_path": "string?",
  "source": "chat_dropped|share_extension|quick_add|smoory_inferred"
}
```

### `link_capture_to_entity`
**Purpose:** Attach a capture item to a project, thread, person, or goal.
**Tier:** tier1_quick
**Inputs:** `{"capture_id": "string", "entity_type": "string", "entity_id": "string", "link_reason": "string?"}`

---

## Write tools — Profile and Infrastructure

### `update_profile`
**Purpose:** Append or modify the profile blob.
**Tier:** tier1_quick
**Inputs:** `{"action": "append|replace|edit_fact", "content": "string", "fact_index": "int?"}`

### `add_quick_fact`
**Purpose:** Add a single quick fact to the profile.
**Tier:** tier1_quick
**Inputs:** `{"fact": "string"}`

### `propose_infrastructure_record`
**Purpose:** Surface a candidate infrastructure record for confirmation.
**Tier:** tier1_quick
**Inputs:** standard `Infrastructure` fields.

### `update_infrastructure`
**Purpose:** Edit an existing infrastructure record.
**Tier:** tier1_quick

---

## Write tools — Rules and learned preferences

### `propose_rule_adjustment`
**Purpose:** Propose a feed-priority rule (e.g. "auto-archive senders matching X").
**Tier:** tier1_quick (the proposal); the adjustment itself is durable
**Inputs:**
```
{
  "kind": "auto_archive_sender|auto_archive_pattern|priority_boost|priority_demote|never_propose",
  "description": "string",
  "pattern": "string",
  "weight": "number?"
}
```

### `update_rule_adjustment`
**Tier:** tier1_quick

### `delete_rule_adjustment`
**Tier:** tier1_quick

---

## Reminders and scheduling tools

### `schedule_reminder`
**Purpose:** Schedule a local notification or feed item for the future.
**Tier:** tier1_quick (when explicitly asked); silent (when a system action like "remind me about X tomorrow" is implicit in another tool)
**Inputs:**
```
{
  "fire_at": "ISO date",
  "kind": "notification|feed_item|nudge",
  "title": "string",
  "body": "string?",
  "linked_entity": {"type": "string", "id": "string"}?
}
```

### `set_off_period`
**Purpose:** Mark a date range as "user is off" (the holiday handler).
**Tier:** tier1_quick
**Inputs:**
```
{
  "start_date": "ISO date",
  "end_date": "ISO date",
  "reason": "string?",
  "actions": {
    "defer_todos": "bool",
    "decline_meetings": "bool",
    "skip_briefs": "bool",
    "auto_reply_email": "bool"
  }
}
```

---

## Tool call patterns by loop type

Different loop types expose different tool subsets to Claude. The orchestrator constructs the tool catalog per call.

### Chat (general)
Full read tools. Most write tools available with tier confirmations.

### Email triage
None (Haiku call returns JSON, no tools).

### Email annotation (correspondence)
Read tools relevant to the email + `propose_*` and `mark_email_for_reply`, `archive_email`, `attach_to_thread`. NOT `send_email` directly — drafting goes through `draft_email`, sending goes through user click.

### Morning brief
Read tools only. Output is structured JSON, not tool calls.

### Day review opener
None.

### Reflective check-in opener
None.

### Structuring layer
None (returns JSON candidates).

### Pattern observation (week review)
Read tools to verify pattern signal; no writes from this call. Confirmed patterns become memory candidates that the user accepts.

### Thread inference
None (returns JSON candidates).

### Tone observation
None (returns JSON delta).

---

## Confirmation flow detail

When Claude returns a tool call for a `tier1` or `tier2` action:

1. The orchestrator does NOT execute immediately.
2. It creates a feed item (or chat card if invoked from chat) with the proposed action and its parameters in human-readable form.
3. The user taps confirm (tier1) or reviews the artifact and approves (tier2).
4. Only then does the orchestrator dispatch the actual function call.
5. Action results return as a `tool_result` message in the assistant's next turn (the Anthropic tool-use protocol).
6. Memory writes are made by the orchestrator after action execution — what was done, when, with what outcome.

For `silent` tools, the orchestrator executes immediately and the result goes to Claude's next turn. No surfacing.

For `tier3_dialog` cases, Claude is prompted to ask the user before generating a concrete tool call at all. The chat exchange happens first; once the user answers, Claude generates the tool call (which itself may still be tier1 or tier2).

---

## Implementation notes

- Tool definitions for the Anthropic API use the `tools` parameter in the Messages API. Each tool has a `name`, `description`, and `input_schema` (JSON Schema).
- Tool descriptions in the API call should be terse but precise — Claude uses them to choose tools, so ambiguity costs accuracy.
- Validate tool call inputs server-side. The model occasionally hallucinates field names or types; reject invalid calls and feed back an error in the tool_result so Claude can self-correct.
- Idempotency keys: for actions that affect external systems (sending email, creating calendar events), include an idempotency key so retries don't duplicate.
- Logging: every tool call (silent or otherwise) is logged with inputs, outputs, and outcome. Useful for debugging and for the memory inspection view.

---

Read **DECISIONS.md** next.
