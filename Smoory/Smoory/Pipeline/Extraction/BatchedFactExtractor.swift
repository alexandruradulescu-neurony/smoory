import Foundation
import SwiftData

/// Trigger labels for telemetry / debug logging. Doesn't affect behavior.
enum ExtractionTrigger: String, Sendable {
    case idlePause              // 15 min silence in chat
    case scenePhaseBackground   // app backgrounded for 5+ min
    case dayReviewPiggyback     // before complete_day_review fires
    case appLaunchGap           // catch turns since last quit
    case manualDebug            // Debug menu trigger
}

/// Salience-gated batched fact extractor (4.4). Replaces per-turn `.fact`
/// extraction in the structuring layer. Caller supplies the input turns;
/// extractor decides via a tiny-LLM salience pre-check whether the heavy
/// extraction pass is worth running.
///
/// State is kept by the caller (caller passes the turns it wants reviewed).
/// The extractor itself only holds an `isExtracting` single-flight flag so
/// concurrent triggers (idle + scenePhase + day-review firing close together)
/// can't double-process the same window.
@MainActor
final class BatchedFactExtractor {
    private let hema: HemaService
    private let modelContainer: ModelContainer
    private let client: LLMClient

    /// Single-flight guard. Concurrent triggers during an in-flight extraction
    /// return without doing anything (the in-flight call covers them).
    private var isExtracting: Bool = false

    init(
        hema: HemaService,
        modelContainer: ModelContainer,
        client: LLMClient = RoutingLLMClient()
    ) {
        self.hema = hema
        self.modelContainer = modelContainer
        self.client = client
    }

    /// Runs salience check. If worthy, runs extraction and persists `.fact`
    /// CandidateWrite rows for the user to review in Feed. Skipped batches
    /// increment the skipped counter; failures increment the failure counter.
    /// Caller supplies the turns; this method does NOT decide what to include.
    func extract(turns: [MemoryTurn], trigger: ExtractionTrigger) async {
        guard !isExtracting else {
            print("[batched] extract(\(trigger.rawValue)) skipped — already running")
            return
        }
        // Two turns minimum so the salience pass has something to reason over.
        // Below that the assistant's per-call write_memory_fact path is
        // already adequate for the rare durable single-utterance case.
        guard turns.count >= 2 else { return }

        // Cap the extraction window. Heavy-tier output is bounded by
        // max_tokens; oversized windows produce lots of facts and the
        // response can be truncated mid-JSON. Salience runs over the same
        // capped window so the verdict reflects what extraction will see.
        // 50 turns ~= a couple of substantive chat sessions, plenty of
        // memory-worthy material; the next trigger picks up overflow.
        let cappedTurns = turns.count > 50
            ? Array(turns.suffix(50))     // most recent 50, chronological order preserved
            : turns

        isExtracting = true
        defer { isExtracting = false }

        // Step 1 — salience gate.
        let verdict: BatchedFactPrompts.SalienceVerdict
        do {
            verdict = try await checkSalience(turns: cappedTurns)
        } catch {
            BatchedExtractionFailureCounter.shared.increment()
            print("[batched] salience LLM call failed (\(trigger.rawValue)): \(error)")
            return
        }

        if !verdict.worthy {
            BatchedExtractionSkippedCounter.shared.increment()
            print("[batched] \(trigger.rawValue): skipped — \(verdict.reason)")
            return
        }
        print("[batched] \(trigger.rawValue): worthy — \(verdict.reason)")

        // Step 2 — heavy-tier extraction. Sees recently-consolidated facts as
        // context so multi-turn arcs ("Maria's my partner" → "she's a doctor")
        // produce coherent companion facts rather than orphan fragments.
        let recentFacts = (try? await hema.readAllFacts(
            filter: FactFilter(
                tags: nil, entities: nil,
                includeExpired: false,
                includeSuperseded: false,
                includePrivate: false,
                minConfidence: nil,
                createdSince: Calendar.current.date(byAdding: .day, value: -30, to: Date()),
                createdBefore: nil
            ),
            limit: 30,
            offset: 0
        )) ?? []

        let parsed: BatchedFactPrompts.ParsedExtraction
        do {
            parsed = try await runExtraction(turns: cappedTurns, recentFacts: recentFacts)
        } catch {
            BatchedExtractionFailureCounter.shared.increment()
            print("[batched] extraction LLM call failed (\(trigger.rawValue)): \(error)")
            return
        }

        guard !parsed.candidates.isEmpty else {
            print("[batched] \(trigger.rawValue): salience said worthy but extraction returned 0 candidates")
            return
        }

        // Step 3 — persist as Feed candidates. Same path as the existing
        // per-turn structuring's `.fact` flow used to take, so 4.1 dedup and
        // 4.3 contradiction detection on confirm both fire normally.
        await persistCandidates(parsed.candidates, trigger: trigger)
    }

    // MARK: - Steps

    private func checkSalience(turns: [MemoryTurn]) async throws -> BatchedFactPrompts.SalienceVerdict {
        let userMessage = BatchedFactPrompts.salienceUserMessage(turns: turns)
        let response = try await client.complete(
            model: .fast,
            systemPrompt: BatchedFactPrompts.salienceSystemPrompt,
            messages: [LLMMessage(role: .user, text: userMessage)],
            tools: nil
        )
        return BatchedFactPrompts.parseSalience(response.text)
    }

    private func runExtraction(
        turns: [MemoryTurn],
        recentFacts: [SemanticFact]
    ) async throws -> BatchedFactPrompts.ParsedExtraction {
        let userMessage = BatchedFactPrompts.extractionUserMessage(
            turns: turns,
            recentFacts: recentFacts
        )
        let response = try await client.complete(
            model: .heavy,
            systemPrompt: BatchedFactPrompts.extractionSystemPrompt,
            messages: [LLMMessage(role: .user, text: userMessage)],
            tools: nil
        )
        return BatchedFactPrompts.parseExtraction(response.text)
    }

    private func persistCandidates(
        _ candidates: [BatchedFactPrompts.ParsedExtraction.Candidate],
        trigger: ExtractionTrigger
    ) async {
        let context = ModelContext(modelContainer)
        var inserted = 0

        // Dedup against ALL existing .fact candidates regardless of status. Pending
        // ones would create Feed duplicates; rejected ones must not re-surface
        // (the user already dismissed that body — re-proposing it on every launch
        // gap-extraction within the 24h window is the nag the prune-sweep + this
        // dedup were added to fix). Confirmed / autoApplied are also covered for
        // free — no point re-asking about a fact already saved.
        let factRaw = CandidateType.fact.rawValue
        let descriptor = FetchDescriptor<CandidateWrite>(
            predicate: #Predicate<CandidateWrite> { $0.typeRaw == factRaw }
        )
        let existing = (try? context.fetch(descriptor)) ?? []
        var seenKeys = Set(existing.map {
            "\($0.typeRaw):\(HemaService.normalizeBody($0.effectiveContent))"
        })

        for candidate in candidates {
            let key = "\(factRaw):\(HemaService.normalizeBody(candidate.content))"
            if seenKeys.contains(key) { continue }
            seenKeys.insert(key)

            let row = CandidateWrite()
            row.type = .fact
            row.content = candidate.content
            row.confidence = candidate.confidence
            row.userPhrase = candidate.userPhrase
            row.status = .pending
            row.sourceKind = "batched_extraction:\(trigger.rawValue)"
            context.insert(row)
            inserted += 1
        }

        do {
            try context.save()
            print("[batched] \(trigger.rawValue): persisted \(inserted) candidate(s)")
        } catch {
            BatchedExtractionFailureCounter.shared.increment()
            print("[batched] \(trigger.rawValue): persist failed — \(error)")
        }
    }
}
