# Smoory

Personal AI assistant macOS app. Single-user, on-device, runs on the user's Mac.
The full spec is in docs/smoory-spec/.

## Read before working

For any task, read the relevant spec docs first:
- Phase 1 (foundation): README.md, ARCHITECTURE.md, RUNTIME.md, DATA_MODEL.md
- Phase 2 (Smoory thinks): + MEMORY.md, AI_PROMPTS.md, TOOLS.md
- Phase 3 (daily presence): + BEHAVIORS.md
- Phase 4 (email): all docs

## Rules

1. The spec in docs/smoory-spec/ is the source of truth.
   If code conflicts with spec, raise it — don't silently diverge.

2. For any architectural decision not covered in the spec:
   - Propose the decision and reasoning in chat
   - Wait for approval
   - Write the decision into docs/smoory-spec/DECISIONS.md before implementing

3. SwiftData model design rules (CloudKit-compatible from day one,
   even though CloudKit is off in v1):
   - All relationships optional
   - No @Attribute(.unique) — use UUIDs as identifiers
   - Default values on all non-optional properties
   - Enums stored as Int raw values

4. Min OS is macOS 14 (Sonoma). Don't use APIs that require newer.

5. Commit small, commit often. Each milestone is its own commit
   with a clear message.

6. Don't add new dependencies without asking. Stick to Apple frameworks
   in Phase 1.

## Currently working on

Phase 1, milestone 1.1: SwiftData @Model definitions for every entity
in DATA_MODEL.md.