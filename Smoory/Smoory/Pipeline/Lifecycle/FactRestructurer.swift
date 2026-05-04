import Foundation
import SwiftData

/// Day-end fact restructurer (4.5). Runs at the day-review piggyback point,
/// AFTER 4.4's batched fact extractor. Reviews today's facts in light of the
/// day's full chat arc and proposes refinement/merge/split/contradict/archive
/// operations as `.factRewrite` Feed candidates for user review.
///
/// Conservative throughout: heavy-tier LLM call with a "lean toward no
/// change" system prompt + a hard cap of 5 operations per day. Failures
/// increment a counter; the day-review summary turn is already persisted
/// before this runs so a restructurer error doesn't lose the user's
/// reflection.
@MainActor
final class FactRestructurer {
    private let hema: HemaService
    private let modelContainer: ModelContainer
    private let client: LLMClient

    private var isRunning: Bool = false

    init(
        hema: HemaService,
        modelContainer: ModelContainer,
        client: LLMClient = RoutingLLMClient()
    ) {
        self.hema = hema
        self.modelContainer = modelContainer
        self.client = client
    }

    /// Runs one restructuring pass over today's facts + today's chat turns.
    /// Caller fires from CompleteDayReviewTool after the summary turn is
    /// persisted and after 4.4's batched extractor has had a chance to
    /// emit any new facts from today's arc.
    func restructure() async {
        guard !isRunning else {
            print("[restructurer] skipped — already running")
            return
        }
        isRunning = true
        defer { isRunning = false }

        let inputs: FactRestructurerPrompts.RestructuringInputs
        do {
            inputs = try await collectInputs()
        } catch {
            FactRestructuringFailureCounter.shared.increment()
            print("[restructurer] input collection failed: \(error)")
            return
        }

        // No facts captured today → nothing to restructure.
        guard !inputs.todayFacts.isEmpty else {
            print("[restructurer] no facts captured today; skipping")
            return
        }

        let parsed: FactRestructurerPrompts.ParsedOperations
        do {
            parsed = try await runLLM(inputs: inputs)
        } catch {
            FactRestructuringFailureCounter.shared.increment()
            print("[restructurer] LLM call failed: \(error)")
            return
        }

        guard !parsed.operations.isEmpty else {
            print("[restructurer] LLM proposed no operations")
            return
        }

        await persistOperations(parsed.operations, inputs: inputs)
    }

    // MARK: - Input collection

    private func collectInputs() async throws -> FactRestructurerPrompts.RestructuringInputs {
        let now = Date()
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let weekAgo = cal.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday

        // Today's chat turns (chronological).
        let turnsRaw = (try? await hema.readAllTurns(limit: 500, since: startOfToday)) ?? []
        let chronological = Array(turnsRaw.reversed())

        // Today's active facts.
        let todayFilter = FactFilter(
            tags: nil, entities: nil,
            includeExpired: false,
            includeSuperseded: false,
            includePrivate: false,    // restructurer never sees private facts
            minConfidence: nil,
            createdSince: startOfToday,
            createdBefore: nil
        )
        let todayFacts = (try? await hema.readAllFacts(filter: todayFilter, limit: 200, offset: 0)) ?? []

        // Recent past facts (last 7 days, excluding today). Read-only context
        // — restructurer is told not to operate on these directly, just to
        // recognize cross-day patterns.
        let recentFilter = FactFilter(
            tags: nil, entities: nil,
            includeExpired: false,
            includeSuperseded: false,
            includePrivate: false,
            minConfidence: nil,
            createdSince: weekAgo,
            createdBefore: startOfToday
        )
        let recentPastFacts = (try? await hema.readAllFacts(filter: recentFilter, limit: 100, offset: 0)) ?? []

        return FactRestructurerPrompts.RestructuringInputs(
            now: now,
            todayChatTurns: chronological,
            todayFacts: todayFacts,
            recentPastFacts: recentPastFacts
        )
    }

    private func runLLM(
        inputs: FactRestructurerPrompts.RestructuringInputs
    ) async throws -> FactRestructurerPrompts.ParsedOperations {
        let userMessage = FactRestructurerPrompts.userMessage(inputs)
        let response = try await client.complete(
            model: .heavy,
            systemPrompt: FactRestructurerPrompts.systemPrompt,
            messages: [LLMMessage(role: .user, text: userMessage)],
            tools: nil
        )
        return FactRestructurerPrompts.parse(response.text)
    }

    // MARK: - Persistence

    private func persistOperations(
        _ ops: [FactRestructurerPrompts.ParsedOperation],
        inputs: FactRestructurerPrompts.RestructuringInputs
    ) async {
        let context = ModelContext(modelContainer)
        let factsByID = Dictionary(uniqueKeysWithValues: inputs.todayFacts.map { ($0.id, $0) })
        var inserted = 0

        for op in ops {
            // Resolve old fact bodies and createdAts. Operations whose
            // referenced facts aren't in today's set (LLM hallucinated an ID)
            // are dropped silently — better to skip than to write a candidate
            // pointing at nothing.
            let resolved = op.oldFactIDs.compactMap { factsByID[$0] }
            guard resolved.count == op.oldFactIDs.count else {
                print("[restructurer] dropping op \(op.op.rawValue) — hallucinated factID(s)")
                continue
            }

            let payload = FactRewriteContent(
                op: op.op,
                oldFactIDs: op.oldFactIDs,
                oldBodies: resolved.map { $0.body },
                newBodies: op.newBodies,
                reason: op.reason,
                oldCreatedAts: resolved.map { $0.createdAt }
            )

            guard let json = encode(payload) else {
                print("[restructurer] payload encode failed for op \(op.op.rawValue)")
                continue
            }

            let row = CandidateWrite()
            row.type = .factRewrite
            row.content = json
            row.confidence = 0.85    // heuristic; LLM doesn't emit a per-op confidence
            row.status = .pending
            row.sourceKind = "fact_restructurer"
            context.insert(row)
            inserted += 1
        }

        do {
            try context.save()
            print("[restructurer] persisted \(inserted) candidate(s) (\(ops.count) proposed)")
        } catch {
            FactRestructuringFailureCounter.shared.increment()
            print("[restructurer] persist failed: \(error)")
        }
    }

    // MARK: - Helpers

    static func decode(_ json: String) -> FactRewriteContent? {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(FactRewriteContent.self, from: data)
    }

    static func encode(_ payload: FactRewriteContent) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    private func encode(_ payload: FactRewriteContent) -> String? {
        Self.encode(payload)
    }
}
