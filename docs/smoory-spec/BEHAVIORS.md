# Behaviors

This document describes what Smoory actually *does*. The architecture says how the system is built; this says what the user experiences.

Each behavior includes: when it fires, what context is built, what the AI does, what surfaces are produced, and what confirmations are requested.

---

## Onboarding (first-run)

**When:** First app launch, after the user provides their Anthropic API key.

**Goal:** Within 20–30 minutes, populate Smoory with enough structured data to be immediately useful — roles, primary goals, key projects, important people, working hours, infrastructure list, profile blob.

**Mechanism:** A guided chat conversation, not a form. Smoory asks open questions, the user answers naturally, the structuring layer extracts candidates in real time. Candidates are confirmed in-line (during onboarding only) rather than batched.

**Conversation arc:**

1. **Greeting and orientation.** Smoory introduces itself: what it is, how it works, the trust model in plain English ("I'll always ask before doing anything that affects others"). Sets expectations: this conversation will take 20–30 minutes, you can quit anytime, what you tell me populates my understanding of you.

2. **The roles question.** "Tell me about your work — the different roles you wear in life." User describes. Smoory proposes Role records as it hears them. User confirms each.

3. **The week question.** "What does a typical week look like across these roles?" User describes. Smoory infers working hours, energy patterns, role-time-allocation. Proposes WorkingHours records.

4. **The goals question.** "What are you trying to make progress on right now? What matters this quarter? This year?" User describes. Smoory proposes Goal records, asks per goal whether it's tracked, reflective, or both. Proposes initial cadences.

5. **The projects question.** "What concrete projects are active right now?" Smoory proposes Project records, links them to goals and roles.

6. **The do-more / do-less question.** "What do you wish you did more of? Less of?" Captures aspirations as candidate goals or candidate habits. Captures friction patterns as profile facts.

7. **The people question.** "Who are the most important people in your work and life right now? Don't list everyone — just the ones I should know about from day one." Smoory proposes Person records with relationship labels.

8. **The infrastructure question.** "What systems and services do you depend on? Where does your business email live, what's your hosting situation, what subscriptions matter to you?" Smoory proposes Infrastructure records.

9. **The patterns question.** "When do you do your best work? When do you struggle? How do you like to be helped?" Captures profile facts about the user's working style, communication preferences, what counts as helpful versus annoying.

10. **The good-day question.** "What does it look like when you have a great day?" Captures aspirational patterns Smoory can use as targets.

11. **The wrap-up.** Smoory summarizes what it learned: "Here's what I now know about you" — renders the populated structure visually (roles, goals, projects, people, profile excerpt). User reviews and edits. The first overall compact summary is generated and stored.

**Onboarding-specific behaviors:**
- Confirmations are in-line (not batched) so the user sees the structure forming in real time.
- The conversation does not need to follow this order exactly — Smoory is allowed to follow tangents and circle back. The arc is a guide, not a script.
- The user can end onboarding at any time; partial onboarding still produces a usable system.
- A "redo onboarding" flow exists in settings for users who want to start fresh after a major life change.

**Output:**
- Populated Roles, Goals, Projects, People, Infrastructure, Profile
- Initial Habits if any emerged
- ~30–60 confirmed semantic facts in hema
- First overall compact summary written
- Smoory is ready for daily use

---

## Continuous learning (post-onboarding)

After onboarding, the structuring layer keeps running on every chat turn, every email annotation, every review. New candidates surface in the feed as `memory_candidate`, `goal_candidate`, `person_candidate`, `infrastructure_candidate`, etc. — batched, low priority, not interrupting current work.

Periodically (perhaps weekly during week review), Smoory may proactively ask:
- "I've heard you mention [topic] a few times — should that be a goal?"
- "I've seen you correspond with [name] regularly — want me to start tracking them as a person?"
- "Your evening pattern has shifted — should I update your working hours?"

These are tier-1 confirmations.

---

## Morning brief

**When:** At a user-configured time each morning (default 08:00 weekdays). Configurable per role or globally.

**Goal:** A 3-minute headline-level briefing that orients the user for the day. Becomes the widget content.

**Context built:**
- Today's calendar window
- Open todos, prioritized
- Active goals with current progress against tracked signals
- Active threads with recent activity
- High-salience operational alerts
- Yesterday's day review highlights (what carried forward)
- Profile and recent compact summary

**AI call:** `claude-sonnet-4-6` with a focused prompt that produces a structured brief.

**Output:**
- A single feed item of kind `morning_brief`, pinned at top of feed for the morning
- A daily focus card written to the widget's JSON cache (which the widget reads on next refresh)
- Optionally a notification (configurable)

**Brief structure:**
- One headline: today's primary focus ("Ship the Apollo spec by 5pm")
- Two or three secondary items
- Calendar at-a-glance: next event, total meeting hours today
- One goal nudge if one is warranted (rate-limited per the goal-nudge rules below)
- One operational alert if any are pinned

**Constraints:**
- Total brief content stays under ~120 words. The user reads this in 30 seconds.
- The widget version is even tighter — abbreviated to fit the medium widget.

**If the user opens the brief and engages:**
The brief item in the feed has tier-1 actions: defer an item, mark something done, expand a goal nudge into a check-in, etc. Engagement is one tap deep.

---

## Day review

**When:** At a user-configured time each evening (default 19:00). Or on-demand from chat ("let's do day review").

**Goal:** 3-minute headline-level reflection. What happened, what slipped, how it felt, what carries forward. Feeds hema's recent compact summary.

**Mechanism:** A guided chat flow, opened from a feed item.

**Flow:**

1. Smoory opens with a recap: "Here's what happened today — [completed todos], [meetings attended], [significant emails handled]. Anything I missed?"

2. Smoory asks about slips: "These didn't get done — [list]. What happened with them?" User answers conversationally. Each slip's reason is captured as a brief reflection.

3. Smoory asks the feel question: "How did the day land for you?" User answers in 1–2 sentences. Captured as a fact.

4. Smoory asks about carry-forward: "Anything to defer to tomorrow? Anything to drop?" User decides. Smoory makes the changes (tier-1 confirms).

5. Smoory shows a tomorrow seed: "Tomorrow has [calendar shape] and [highest-priority pending todos]. Want anything else on the plate?" User can add things or close.

**Total time target:** 3 minutes. The user can choose "deep dive" at any step to extend.

**Output:**
- Day review feed item (archived after completion, searchable in history)
- Updated `today` compact memory
- Updated `recent` compact memory (regenerated)
- Semantic facts: reflections, slip reasons, feel observations
- Any deferred todos updated

**If skipped:**
The next morning's brief includes a 30-second catch-up prompt: "We missed day review yesterday — anything I should know before today starts?" One missed day is fine; two in a row leaves a hole in memory.

---

## Week review

**When:** Sunday evening at user-configured time (default 19:00). Or on-demand.

**Goal:** 3-minute headline-level recap of the week, plus opt-in goal check-ins.

**Flow:**

1. Smoory opens with the week recap: "This week — [N todos completed, M meetings, K significant emails handled, L threads opened/closed]. [One sentence on overall shape]."

2. Smoory shows goal progress with concrete numbers where possible: "Reading goal: logged 6 sessions, target 7. Half-marathon training: missed 2 runs. Apollo project: shipped 2 milestones."

3. Smoory shows pattern observations (output of an Opus call over the week's data): "You completed 80% of morning todos and 40% of afternoon ones. Every meeting that moved this week, the prep todo for it slipped." Each pattern is a candidate semantic fact awaiting user confirmation.

4. Smoory offers reflective check-ins: "Want to do reflective check-ins on any of your goals this week? Reading, exercise, the half-marathon prep, your business — any you want to talk about?" User picks zero, some, or all.

5. **For each picked goal:** a focused conversation (see "Reflective check-in" below).

6. Wrap: "Anything to adjust for next week? Goals to pause, projects to drop?" User can make structural changes via chat.

**Total time:** 3 minutes for the recap; 3–8 more minutes if the user opts into multiple check-ins. Always opt-in to extend.

**Output:**
- Week review feed item, archived after
- Updated `recent` compact memory (regenerated based on week)
- New `overall` compact memory (regenerated)
- Pattern observations as semantic facts (after confirmation)
- Goal status changes (paused, achieved, dropped) per user decisions
- A populated planning context for the next week

---

## Reflective check-in (per-goal)

**When:** During week review (opt-in), or on the goal's individual cadence (weekly, biweekly, monthly, quarterly), or on-demand from chat.

**Tone:** Curious, not judgmental. The persona for this flow is more therapist-shaped than executive-assistant-shaped. The user is talking about a goal that may not be going well, and the conversation should make them feel understood, not graded.

**Flow:**

1. Smoory opens with a specific, observation-led question rather than a generic one. **NOT** "How is reading going?" but rather: "I noticed you logged 3 reading sessions this week instead of 7. Your evenings ran long with work emails — anything getting in the way?"

   The specificity comes from hema retrieval before the check-in: Smoory pulls relevant facts from the past week, identifies plausible blockers, and crafts an opening that demonstrates understanding.

2. User responds. Smoory listens (no probing follow-ups unless the user volunteers more). Asks one or two open follow-ups if natural.

3. Smoory offers concrete help, framed as proposals: "Want me to be more aggressive about silencing work after 8pm? Or schedule a 15-minute reading slot Tuesday and Thursday mornings?" Each proposal is a tier-1 confirm.

4. Smoory offers goal-level adjustments if relevant: "Want to pause this for a couple weeks while work is heavy? Change the target?" Goal status changes are tier-1.

5. Smoory closes with care: "Thanks for talking through this — I'll keep an eye out for [specific thing]." A semantic fact is written: "User says [reason] is the main blocker for [goal] right now."

**Constraints:**
- Smoory does not lecture, push, or judge. The voice is *curious* throughout.
- If a goal has been failing for 3+ check-ins with no improvement and no proposed action helping, the next check-in's opening becomes: "[Goal] hasn't been progressing for a while. Is this still something you want to hold? It's OK to revise, pause, or drop a goal."
- Goals are not sacred. The check-in respects the user's right to drop or change goals at any time.

---

## Goal nudges

**When:** Within the morning brief, or as a feed item if a tracked goal is significantly off-pace mid-week.

**Rate limits:**
- Maximum one goal nudge per morning brief
- Never three nudges in a row about the same goal without an intervening reflective check-in
- Nudges paused for goals with status `.paused`
- Nudges suppressed during user-flagged "off" periods (holidays, illness, deep-work blocks)

**Selection:** When multiple goals warrant a nudge, the most off-pace tracked goal is selected. Tie-breaker: the one least nudged recently.

**Tone:** A nudge is a re-offer, not a guilt trip. *"Reading hasn't happened in 4 days — want me to put 30 minutes on the calendar this evening?"* — the user can say yes (Smoory schedules), no thanks, or "let's talk about it" (escalates to a reflective check-in).

**After two consecutive ignored nudges:**
The third "nudge" is replaced with a reflective check-in opener: *"Reading hasn't been happening — is this still a goal you want to hold, or has it changed?"*

---

## Email arrives — full pipeline

**Trigger:** Mail Rule fires, AppleScript hook pokes Smoory with the new message ID. Smoory reads the message body and metadata from the local Mail database.

**Stage 1 — Cheap triage call (Haiku):**
Input: subject, sender, first 200 chars of body, sender's domain, whether the address is in Apple Contacts.
Output: classification — one of `noise`, `receipt`, `calendar_invite`, `alert_action`, `alert_info`, `correspondence`, `ambiguous`.

**Stage 2 — Routing by classification:**

### `noise`
Drop. No memory write. No feed item. No further processing. Counter incremented for stats.

### `receipt`
Silently log to a `transactions` view. Searchable later ("how much did I spend on AWS in March?"). Extract amount, vendor, date as structured fields. No feed item. A semantic fact may be written if the receipt reveals new infrastructure ("user has a Stripe account") and that infrastructure isn't already known.

### `calendar_invite`
Route to calendar pipeline (read-only in v1; just notify the user that an invite landed and let them respond from Mail).

### `alert_action` (FAST PATH)
Operational alert requiring action. Examples: payment failure, expiring domain, certificate renewal, server bill, account warning.
- Enrichment runs immediately with full context — including matching infrastructure record, recent related activity, similar past alerts.
- Feed item generated with `pinned: true` and high priority.
- The proposed action(s) attempt to be specific: "Add tier-1 todo to renew domain by [date]; remind tomorrow morning if not resolved" — not generic ("review this email").
- Notification fires (this is one of the few notification triggers).

### `alert_info`
Informational, no action needed. Low-priority feed item. Smoory may write a semantic fact ("server reboot completed, 14:32 today").

### `correspondence`
Full enrichment pipeline (see "Correspondence enrichment" below).

### `ambiguous`
Default to `correspondence`. Better to over-process than miss something. Smoory may surface ambiguous calls for periodic feedback ("I almost dropped this as noise — should I have?") to refine triage over time.

---

## Correspondence enrichment

**Stage 1 — Context assembly:**
- Email body and headers
- Sender's Person record (if exists, including tone profile if mature enough)
- Hema retrieval over recent conversation history with this person, related people, and the email's subject keywords
- Open threads where this email might fit
- Active todos referencing this person or this topic
- Calendar window relevant to dates mentioned in the email
- Profile blob

**Stage 2 — AI call (Sonnet):**
A focused prompt produces:
- A short annotation (1–3 sentences) explaining what this email is about in context
- A thread inference: does this email belong to an existing thread, a new thread, or no thread?
- A proposed action set: 0–3 actions with their parameters (create todo, draft reply, archive, defer, link to project, etc.)
- A relevance flag: low / medium / high. Low-relevance correspondence (e.g. routine "thanks!") becomes a quiet feed item or no feed item at all.

**Stage 3 — Surface:**
- Feed item of kind `email_annotation`, with the annotation as `body`, the actions as proposed cards.
- If thread inference proposes a new thread, an additional `thread_proposal` candidate is written for the user to confirm.
- The email's vector is added to the related thread's context for future retrieval.

**Stage 4 — Action execution after user confirm:**
Each action has its own tier:
- Create todo: tier 1, single tap
- Mark email as needing reply: tier 1
- Archive email: tier 1
- Draft reply: tier 2 (Smoory generates the draft, user reviews, sends)
- Send reply: tier 2 (always; sending email always reviewed)

**Memory writes:**
- Smoory's annotation is embedded into hema as a memory turn
- Person interaction count incremented
- Person's tone profile updated if the email is from a tracked person (silently, accumulating observations toward the threshold)
- Any structurable facts in the email body become semantic fact candidates ("the meeting on Friday was moved to next week")

---

## Thread inference

**When:** During correspondence enrichment, or when the user sends a batch of similar outgoing emails (the "10 quote requests" example).

**Detection signals:**
- Multiple emails sent within a short window (<2 hours) to different recipients with similar subjects
- Multiple replies to a single original outgoing email
- Subject prefix patterns ("Re: Quote request - X", "Re: Quote request - Y")
- Cross-referenced topic mentions
- Manual creation by the user

**Mechanism:**
A small Claude call (Haiku, batched periodically rather than per-email) groups recent activity into candidate threads with confidence scores. High-confidence groupings (≥0.85) are proposed in feed as `thread_proposal` items: "Looks like these 10 emails belong together — track as a thread?"

**Once confirmed:**
Future activity (replies, related todos, draft emails) auto-attaches to the thread. The thread accumulates events. The thread has a rolling summary regenerated when significant new activity arrives.

**Auto-close:**
- `awaiting` for 14 days with no activity → propose close
- All linked todos completed AND no email activity for 7 days → propose close
- User says "we're done with X" in chat → close immediately

---

## Per-contact tone profiles

**Goal:** Drafts to a specific person sound like how the user writes to that person.

**Mechanism:**
- Every outgoing email the user actually sends (after review) is fed back to a tone-observation pass that updates the person's `ToneProfile`.
- Specifically, the pass extracts: register (formal/casual), length preference, greeting and sign-off patterns, recurring stylistic signatures.
- Observations are accumulative — each new email adjusts the profile slightly rather than replacing it.

**When tone profiles are USED:**
- After `observationCount >= 5` for a person, their tone profile is included in drafting prompts.
- Below that threshold, drafts use the user's generic default voice (which is itself learned from all outgoing emails over time).

**Transparency:**
- Each Person record's view (when retrieved into chat) shows the inferred tone — what Smoory thinks about how the user writes to them.
- The user can edit or override the tone profile in a `ToneOverride`.
- When Smoory drafts a reply, it states which tone is being used in a small subtitle: *"Drafting in your voice for Emil — first-name, terse, structured."* No interruption; just visibility.

---

## "I'll be off for two days" — the holiday command

**Trigger:** User says something in chat that conveys availability change. Examples:
- "I'll be off Tuesday and Wednesday for the national holiday"
- "I'm traveling next week"
- "I'm sick today"
- "I have a deep work block Tuesday morning"
- "I'm at a conference Thursday-Friday"

**Detection:** The structuring layer recognizes availability-change patterns. This is one of several explicitly-recognized fact categories (alongside goals, todos, people, etc.).

**Behavior:**

1. Hema writes a high-salience semantic fact with an `expires_at` matching the off-period:
   *"User off [start_date] – [end_date]. Reason: [reason if given]."*

2. Smoory's reasoner (Sonnet) immediately follows up actively, not passively. *Not:* "Noted." *Instead:*
   *"Got it. I see you have 3 todos due those days and one meeting on day 1. Want me to: defer the todos to [next available day], decline the meeting, set Mail to send a brief auto-reply, and skip morning briefs both days?"*

3. Each suggestion is a tier-1 or tier-2 card depending on its action type. User confirms what they want.

4. Smoory acts. The fact persists in hema until expiry.

5. **During the off-period:**
   - Every context bundle includes the off-period fact.
   - Morning briefs are skipped (or replaced with "you're on holiday — back [date]").
   - The widget shows "on holiday" instead of focus cards.
   - Email triage applies a "lower urgency" multiplier — only `alert_action` items still surface in real time; everything else queues for return.
   - Goal nudges are paused.
   - Reviews are deferred.

6. **On return:**
   - Smoory greets with a return-from-holiday brief: queued items, what came in, what waited.
   - Off-period fact expires.

**Generalization:**
Other availability statements work the same way with appropriate modifications:
- "Deep work block Tuesday morning" → fact with narrow time window; Smoory protects the calendar slot, defers nudges and notifications during it.
- "I'm sick today" → fact for one day; aggressive deferral of non-critical items.
- "I'm traveling next week" → fact for the week; reduced expectation on goal nudges, may proactively prep travel-related todos (charge devices, pack, OOO setup).

---

## Operational alert handling

**The "I forgot to pay the server bill" pattern:**

When triage classifies an email as `alert_action`, the enrichment pass produces an aggressive proposal:
- Add a tier-1 todo with the alert's deadline as the due date
- Pin a feed item until the user resolves it
- Schedule a follow-up nudge for the next morning if the todo isn't completed
- Optionally fire a notification (configurable per alert source)

**Smoory's job is not to relay the email** — it's to convert the alert into an action plan and a tracked commitment.

**Recognition signals (for triage):**
- Sender domain matches a known infrastructure provider (Stripe, GitHub, AWS, registrar, etc.)
- Subject keywords: "expir", "fail", "overdue", "renewal required", "action needed", "payment"
- Body language indicating consequence: "service will be suspended", "domain will be released"

The triage classifier is trained on these patterns through the system prompt; precision improves over time as the user confirms or corrects classifications.

---

## Drafting an email

**Triggered by:** Chat message ("draft a reply to Emil with the status"), or a tier-2 action proposal in a feed item, or a quick-action.

**Context built:**
- The recipient's Person record (with tone profile if mature)
- The thread state if the email is part of a thread
- Any specific content the user provided (status to convey, ask, tone hints)
- The user's generic outgoing-email voice profile
- Recent emails the user has sent to this person (for stylistic reference)

**AI call:** Sonnet with a focused drafting prompt.

**Output:** Email body and subject, returned to the orchestrator.

**Surface:** Feed item of kind `email_draft` (or chat reply if drafted from chat) with the full draft visible. Tier-2 confirmation: user can edit the draft before sending. The "send" button triggers AppleScript to push the email to Apple Mail's send queue (or directly send, depending on configuration).

**Memory writes:**
- After send, the sent message is added to hema (vector embedded).
- The recipient's `ToneProfile.observationCount` increments; the tone-observation pass updates the profile.

---

## "Who was that guy from that company doing X" — the retrieval question

**Pattern:** User asks a vague identification question in chat, often weeks or months after the fact, with partial information.

**Behavior:**

1. The chat enrichment runs. Hema retrieval is configured for People-search:
   - Vector search over `semantic_facts` filtered by `entities_referenced` containing person IDs
   - Vector search over `memory_turns` for conversational mentions matching the query
   - Vector search over Person records' notes and observations
   - Joined with structured filters where possible (date range, role)

2. Top candidates are returned to Sonnet, which reasons over them: *"Based on the user's query, the candidate is most likely [Person X], because they were mentioned in the context of [topic] in [time frame]."*

3. Smoory replies with the answer, the source ("you mentioned them after the conference in March"), and offers next-step actions: *"Want me to draft an email to them?"* tier-2.

4. If multiple candidates are plausible, Smoory disambiguates: *"Could be Maria from Acme or Tomás from Helia — both fit. Which one?"*

5. If no clear match, Smoory says so honestly: *"I don't have a clear match. Tell me a bit more — when did this come up, what were they working on?"* The follow-up tightens retrieval.

**This is the killer use case for hema.** Without semantic memory, vague identification queries can't work; with hema, they're a regular feature.

---

## Capture flows

**Sources in v1:**
- Drag and drop a file onto the chat panel
- Quick-add hotkey (configurable, default `⌘⇧N`) opens a small input box for a typed thought
- Chat message that contains a link or a captured idea

**Behavior:**
- The capture is stored as a `CaptureItem`.
- A small Claude call (Haiku) triages it: what is this, where might it belong?
- A feed item proposes filing it: link to project, attach to thread, propose as todo, propose as goal, save as note. Tier-1 confirm.
- If the capture is a PDF or image, text extraction runs (Vision framework or PDF text extraction) and the extracted text is added to the capture for future retrieval.

**Post-v1:** share extension, browser plugin, voice memo capture, screenshot capture.

---

## Cross-everything search (post-v1)

A unified search surface that queries across:
- Hema vector memory
- Hema semantic facts
- Structured state (todos, projects, threads, people)
- Captured items
- Email metadata (cached)
- Calendar events

Returns ranked results across types, with previews and navigation. Implementation deferred to post-v1 because it requires unified vector indexing across sources.

---

## End-of-day shutdown ritual (post-v1)

A specific flow that helps the user *stop working*: closes browser tabs (via Chrome integration), summarizes the day's open threads, queues tomorrow's first thing, then declares Smoory quiet until morning. Adjacent to day review but distinct — about transitioning out of work mode rather than reflecting on the day.

Mentioned here for completeness; deferred to post-v1.

---

Read **AI_PROMPTS.md** next.
