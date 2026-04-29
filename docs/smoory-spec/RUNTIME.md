# Runtime: Communication and Provider Portability

This document covers two architectural questions:

1. **How does Smoory's AI brain communicate with your machine?** What data leaves your Mac, what stays?
2. **Are you free to swap LLM providers?** What does that take?

Both are about runtime architecture — how the system actually executes once it's built.

---

## Part 1: How AI communicates with your machine

### Where things live

| Side | What it holds | What it does |
|---|---|---|
| **Your Mac** | The Smoory app (Swift), all your data (SwiftData store + sqlite-vec hema), all tools, all UI surfaces, all of Apple's frameworks (EventKit, Contacts, Mail) | Captures sensor events, assembles context, executes tools, renders surfaces, writes memory |
| **Anthropic's servers** | Claude (the LLM) | Receives a prompt, returns a response. No persistent state. No memory between calls. |

The boundary between them is **a single HTTPS POST request per call**. That's it.

### A typical request lifecycle

Walk through a chat turn end-to-end:

**Step 1 — Sensor event on your Mac**
You type a message. Or the Mail Rule fires. Or the morning brief scheduler triggers. The event handler runs locally, in the Smoory app, on your Mac.

**Step 2 — Context assembly on your Mac**
Smoory queries your local data:
- SwiftData for open todos, active goals, today's calendar, the matching person/thread/project
- sqlite-vec for hema retrieval (top-k facts and turn excerpts relevant to the current input)
- Apple frameworks for live data (EventKit calendar events, Contacts records, Mail body)
- Profile blob and compact memory summaries

The orchestrator picks a *context recipe* matching the call type (chat, email annotation, morning brief, etc.) and packs only what that recipe specifies. Different recipes pull different subsets.

**Step 3 — One HTTPS POST to Anthropic's API**
Smoory makes a single network call to `api.anthropic.com/v1/messages`. The request body contains:

- `model`: which Claude model to use (`claude-haiku-4-5`, `claude-sonnet-4-6`, or `claude-opus-4-7`)
- `system`: the system prompt for this call type (from `AI_PROMPTS.md`)
- `messages`: assembled context + the active payload (your message, the email body, etc.)
- `tools`: JSON schemas of the tools Claude is allowed to request (just shapes — no data)
- `max_tokens`, `temperature`, etc.

This is the only network call in the loop. Nothing else leaves your Mac.

**Step 4 — Anthropic processes the prompt**
On Anthropic's servers, statelessly. Anthropic does not store the request between calls, has no profile of you, retains nothing beyond what's needed to return the response (and per their API policy, does not train on API data). The response comes back as text content + optional tool-use requests.

**Step 5 — Response handling on your Mac**
Smoory parses the response:
- Text content → renders to your chat surface or feed item
- Tool-use requests → the orchestrator's confirmation logic kicks in:
  - **Silent tier** (read tools): execute immediately, get result
  - **Tier-1**: surface a confirmation card in the feed/chat; user taps; execute on confirm
  - **Tier-2**: surface the full proposed artifact (e.g., draft email body); user reviews and edits; execute on approval
  - **Tier-3**: surface as a chat dialog; user answers; the tool call may then be re-issued

**Step 6 — Tool execution on your Mac**
When Claude requests `create_todo`, your Mac's `TodoService` creates a SwiftData record. When Claude requests `send_email`, your Mac's `MailService` invokes AppleScript to push to Apple Mail. When Claude requests `archive_email`, AppleScript moves the message in Apple Mail.

**Anthropic never executes anything on your Mac.** The API only returns the structured request *"I want to call this tool with these parameters."* Your Mac decides whether and how to execute.

**Step 7 — Tool result back to Anthropic**
For tools that ran (silent or after confirmation), the orchestrator sends a follow-up API call to Anthropic with the tool result so Claude can produce its final user-facing response. This is the standard Anthropic tool-use protocol — you can have multi-turn tool exchanges within a single user request.

**Step 8 — Memory writes on your Mac**
After the turn completes, hema writes the conversation turn to sqlite-vec. The structuring layer (a parallel small Claude call) extracts candidate facts. Confirmed semantic facts get written. All locally.

### Visual flow

```
   YOUR MAC                                    ANTHROPIC

   [Sensor: chat / email / scheduled]
              │
              ▼
   [Context assembly]
   ┌─ SwiftData (todos, goals, etc.)
   ├─ sqlite-vec (hema retrieval)
   ├─ EventKit, Contacts, Mail
   └─ Compact summaries
              │
              ▼
   [HTTPS POST]   ────────────────────────▶  [api.anthropic.com]
                                                     │
                                             [Claude processes]
                                                     │
   [HTTPS response]   ◀───────────────────────       │
              │
              ▼
   [Parse response]
              │
        ┌─────┴─────┐
        ▼           ▼
   [Text reply]  [Tool requests]
                       │
                       ▼
              [Confirmation tier?]
                       │
                  ┌────┴────┬─────┬──────┐
                  ▼         ▼     ▼      ▼
                silent    tier-1 tier-2  tier-3
                  │         │     │      │
                  └────┬────┴─────┴──────┘
                       ▼
              [Execute tool locally]
                       │
                       ▼
              [Tool result] ─────────────▶  [api.anthropic.com]
                                            (follow-up turn)
                       │
                       ▼
              [Memory writes locally]
                       │
                       ▼
              [Surface to user]
```

### What data leaves your Mac

For each Anthropic API call:

**Sent:**
- The system prompt for this call type
- The current message context (what you typed, or the email being processed)
- A *filtered subset* of relevant memory (relevant facts, relevant past turns, the matching person/thread/project, today's calendar)
- Tool schemas (just shapes — no data)

**Stays on your Mac:**
- The full SwiftData store
- The full hema database (all memory turns, all facts, all summaries)
- All tool implementations
- All your personal data not explicitly relevant to the current call
- Profile facts marked as private (excluded from API context even when relevant)

### Per-call filtering

The orchestrator does NOT dump everything to every call. Each call type has a context recipe specifying what to include:

| Call type | Memory included |
|---|---|
| Chat reply | Top-k vector retrieval over user message; compact summaries; relevant entities |
| Email annotation | Sender's facts and tone profile, matching thread, related todos, today's calendar |
| Morning brief | Recent compact summary, today's calendar, open priority todos, active goals |
| Triage classifier | Subject, sender, body excerpt only — no memory at all |
| Structuring layer | The user message + 4–6 prior turns + existing roles/goals/people for deduplication |
| Reflective check-in | The goal, its progress data, facts about that goal area, past check-ins |
| Pattern observation (week review) | Full week's structured state changes, day reviews, chat turns |

This filtering serves two purposes: privacy (less data leaves the Mac) and quality (smaller, focused contexts produce better Claude responses).

### Private-fact flag

Any semantic fact in hema can be marked as private. Private facts are never included in any API call's context, even if the retrieval system would otherwise pick them up. Useful for things you'd like Smoory to remember locally but not actively reason about externally.

### Network footprint

For a typical day at expected volume:
- ~30–50 chat-turn API calls (Sonnet for replies, Haiku for parallel structuring layer)
- ~100 email-triage API calls (Haiku, fast and cheap)
- ~5–10 enrichment API calls for correspondence (Sonnet)
- 1 morning brief (Sonnet), 1 day review opener (Sonnet)
- Weekly: 1 week review opener (Sonnet), 1 pattern observation (Opus)

Total: ~150–200 API calls/day, ~$5–15/month at Anthropic's API pricing.

All HTTPS to a single domain (`api.anthropic.com`). No third-party telemetry, no analytics, no other network endpoints in the core loop.

### Trust boundary summary

| Side | Holds | Sees |
|---|---|---|
| Your Mac | All data, all execution, all memory writes, all UI | Everything |
| Anthropic | The AI brain (stateless) | Only the per-call filtered context |

The boundary is the HTTPS request body. Whatever goes into a single request is the maximum exposure of your data per call. Anthropic's API policy is no training on API data and limited retention for abuse-monitoring; refer to their current terms for specifics.

### What never happens

- Anthropic never reads files from your Mac
- Anthropic never accesses your Apple Contacts, Calendar, or Mail directly
- Anthropic never holds state between calls — every request is fresh
- Anthropic never executes a tool — it only requests one in its response
- Smoory never sends data to anywhere other than the configured AI provider's API
- Smoory never auto-shares, auto-syncs, auto-backs-up to any cloud service in v1

---

## Part 2: LLM provider portability

You're free to use a different provider. The architecture supports it. But it's not free, and starting with Anthropic is the recommendation.

### Why Anthropic by default

Smoory's design assumes Claude. Specifically:

- **Voice and behavior tuning.** The system prompts in `AI_PROMPTS.md` are written for Claude's register. Claude has a particular conversational voice that the prompts work with; the same prompts produce subtly different outputs on other models.
- **Tool-calling reliability.** Claude is among the strongest models for structured tool use and for adhering to JSON output formats. Smoory leans on this heavily — the structuring layer, triage classifier, and tool dispatching all assume reliable structured outputs.
- **Three-model tiering.** Anthropic's Haiku/Sonnet/Opus tiers map cleanly onto Smoory's call-type routing (cheap classification, default reasoning, heavy pattern observation). Other providers have similar tiers but the cost/quality ratios differ.
- **Context window.** Claude's 200k context is generous enough that aggressive context filtering is a quality concern, not a survival concern.

### What it would take to switch

Most of Smoory is provider-agnostic. The data model, the surfaces, the tools, the memory layer — none of it cares which LLM is on the other end. The work is concentrated in three places:

**1. The LLM client abstraction**

A Swift protocol that the rest of Smoory talks to:

```swift
protocol LLMClient {
    func complete(
        model: ModelTier,
        systemPrompt: String,
        messages: [LLMMessage],
        tools: [LLMTool]?
    ) async throws -> LLMResponse
}

enum ModelTier { case fast, balanced, heavy }
```

Implementations:
- `AnthropicClient` — primary
- `OpenAIClient` — adapter
- `OllamaClient` — adapter for local models
- `GeminiClient` — adapter

The orchestrator picks the tier (`fast` for triage, `balanced` for chat, `heavy` for week-review patterns), and the client maps tier → concrete model for that provider.

**2. Tool schema translation**

Anthropic, OpenAI, Gemini, and Ollama all support tool/function calling but with different JSON shapes. Tool definitions live as portable structures internally and get translated at the client boundary.

For example, Anthropic uses:
```json
{ "name": "create_todo", "description": "...", "input_schema": { ... } }
```

OpenAI uses:
```json
{ "type": "function", "function": { "name": "create_todo", "description": "...", "parameters": { ... } } }
```

The translation is mechanical, but it has to exist.

**3. System prompt tuning**

Voice and behavior aren't fully captured by prompt tokens. A prompt that produces a great Claude response may produce a flat or weirdly verbose GPT-4o response. Switching providers means a prompt-tuning pass against the new model. Plan a few hours per provider for this.

### Provider notes

**OpenAI (GPT-4o, o-series)**
- Tool calling: strong. Different JSON shape; translation is mechanical.
- Context window: 128k for GPT-4o. Sufficient.
- Cost: similar order of magnitude to Anthropic.
- Quality on Smoory's tasks: good but not Smoory-tested. The voice differs — drafts and reflective check-ins will sound different.

**Google Gemini (2.0 Flash, Pro)**
- Tool calling: works. Occasionally less consistent than Anthropic/OpenAI.
- Context window: 1M tokens advertised; effective utility drops past ~128k as the HEMA paper notes.
- Cost: cheap (especially Flash).
- Multimodal-first design — useful if you ever extend Smoory to voice or image inputs.

**Local models via Ollama or LM Studio**
- Examples: Llama 3.3, Mistral Large, Qwen 2.5
- Tool calling: viable on the better recent models (Llama 3.3 70B+, Qwen 2.5 32B+); brittle on smaller.
- Privacy: nothing leaves your Mac. This is the strongest privacy posture.
- Quality: the gap to Claude/GPT-4 on Smoory's nuanced tasks (tone-matched drafting, reflective check-ins, pattern observation) is real but narrowing. Triage and structuring layer (classification-shaped tasks) work fine on local models. Enrichment, drafting, and reviews suffer more.
- Latency: 5–30 seconds per call typical on M-series Macs. Brief delivery feels different at this latency.
- Recommendation: viable for triage and the structuring layer (high-volume cheap calls). Probably want a hosted model for chat/drafting/reviews where quality differences land directly in the user experience.

### Hybrid configurations

The cleanest portable design supports a hybrid. For example:
- **Triage**: local Ollama (Llama 3.3 8B) — high volume, simple classification, latency tolerable
- **Structuring layer**: local Ollama — high volume, simple extraction
- **Chat / drafting**: Anthropic Sonnet — quality matters, latency matters
- **Pattern observation (weekly)**: Anthropic Opus — once a week, quality matters most

Routing happens in the orchestrator's call-dispatch logic. Each call type gets a configured provider tier.

### Embeddings

Already provider-agnostic. Smoory uses Apple's `NLEmbedding` for v1 — local, free, on-device. Swappable through an `Embedder` protocol:

```swift
protocol Embedder {
    var dimension: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}
```

Alternatives:
- OpenAI `text-embedding-3-small` (1536-dim, hosted, ~$0.02/1M tokens) — what the HEMA paper uses
- Voyage AI (multiple models, hosted)
- Local embedders via Ollama (e.g., `nomic-embed-text`) — same privacy guarantees as local LLMs

Vector dimension changes require re-embedding the corpus, which at personal scale is cheap (a few minutes for thousands of items). Build the swap path explicitly so re-embedding is one command.

### Configuration in the app

Recommended settings UI in Smoory:

- **Provider for chat/drafting/reviews** — selector: Anthropic / OpenAI / Gemini / Local
- **Provider for triage and structuring** — separate selector; can default to a cheaper option
- **Provider for heavy reasoning (week-review patterns)** — separate selector; can default to the same as chat
- **API keys** for whichever providers are selected (stored in Keychain)
- **Embedder** — selector: Apple NLEmbedding / OpenAI / Local
- **Spending ceilings** — daily/monthly hard stop on hosted provider spend

Defaults: Anthropic Claude across all tiers, NLEmbedding for embeddings. Most users don't change these.

### Migration path

If you start on Anthropic and later decide to switch:

1. Implement the new provider's adapter behind `LLMClient`
2. Run a tuning pass on the system prompts in `AI_PROMPTS.md` against the new provider
3. Empirically test triage accuracy, drafting quality, and check-in tone against your existing usage
4. Switch via settings; the new provider takes over going forward
5. Past chat history doesn't need migration — it's just text; the next response comes from the new provider

The hema database is provider-agnostic (vectors and text) and migrates with no changes.

### What to NOT do

- Don't switch providers mid-session if avoidable. Claude and GPT-4o produce subtly different responses to the same context, which can confuse the user.
- Don't run two providers in parallel for the same call type to "compare." Wasted spend and ambiguous product behavior.
- Don't switch *because* of a single bad output from the current provider. Tune the prompt first.
- Don't mix hosted-provider context with private facts you've explicitly marked private. The private flag must be respected at the orchestrator boundary, not at the provider client.

---

## Summary

**Communication.** Every AI call is a single HTTPS POST to one provider's API (Anthropic by default). Your data stays on your Mac except for the per-call filtered context. Tools execute locally. The AI is stateless on the provider side.

**Portability.** The architecture is provider-agnostic behind an `LLMClient` abstraction. Switching providers is real work — adapter implementation plus prompt tuning — but not a re-architecture. Local-only via Ollama is feasible for high-volume cheap call types, and viable end-to-end for users who prioritize absolute privacy over response quality.

The product as designed assumes Anthropic; the product as architected can run on anything that speaks tools-and-text.

---

Read **DATA_MODEL.md** next.
