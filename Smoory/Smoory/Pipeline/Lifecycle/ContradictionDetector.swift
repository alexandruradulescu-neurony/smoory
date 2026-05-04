import Foundation

/// Detects facts in hema that may genuinely contradict a newly-written fact.
/// Hybrid approach:
///
///   1. Embedding-similarity SHORTLIST — top-5 active facts most similar to
///      the new fact's body (vec0 nearest-neighbor). Fast, no LLM.
///   2. EARLY EXITS — empty shortlist returns immediately; small shortlists
///      (<2) skip the LLM and fall back to a pure-similarity threshold so a
///      fresh database with one or two facts doesn't pay the per-write LLM cost.
///   3. LLM CONTRADICTION CHECK — `claude-sonnet`-class call (.balanced tier)
///      with a conservative system prompt that leans toward false negatives.
///   4. CAP — at most 3 contradictions per write, top-K by similarity, so a
///      pathological response can't spam the Feed.
///
/// Failure mode is fire-and-forget: every error path returns either the
/// timeout-fallback hint or [], and the upstream `Task.detached` caller
/// increments `ContradictionDetectionFailureCounter.shared` on a thrown error.
@MainActor
final class ContradictionDetector {
    private let hema: HemaService
    private let client: LLMClient

    private static let shortlistK = 5
    /// Cosine-similarity threshold used when the shortlist is too small to ask
    /// the LLM (keeps the early-database path cheap and deterministic).
    private static let pureSimilarityThreshold: Double = 0.85
    private static let llmTimeoutSeconds: TimeInterval = 5
    /// Cosine-similarity floor for the timeout fallback's top-1 pick. Higher
    /// than the shortlist threshold because we're committing to "probably
    /// contradicts" without LLM confirmation.
    private static let llmTimeoutFallbackThreshold: Double = 0.9
    private static let maxContradictionsPerWrite = 3

    init(hema: HemaService, client: LLMClient = RoutingLLMClient()) {
        self.hema = hema
        self.client = client
    }

    /// Returns 0–N active facts that may contradict `newFactBody`. `excludingID`
    /// is set to the just-written fact's id so the detector doesn't flag it
    /// against itself. Caller is responsible for translating the result into
    /// supersession candidates.
    func detect(newFactBody: String, excludingID: UUID?) async throws -> [SemanticFact] {
        // Step 1: shortlist via embedding similarity. excludePrivate=false so
        // contradictions on private facts are surfaced too — the user benefits
        // from clean private state. The resulting supersession candidate
        // surfaces private content briefly during user review (documented
        // trade-off; the user is the only viewer).
        let candidates = try await hema.retrieveSimilarFacts(
            query: newFactBody,
            k: Self.shortlistK,
            excludeExpired: true,
            excludePrivate: false,
            excludeSuperseded: true
        )
        .filter { $0.0.id != excludingID }

        guard !candidates.isEmpty else { return [] }

        // Step 2: small-database fast path. With <2 shortlist entries, skip the
        // LLM and use a strict similarity threshold. Avoids per-write LLM cost
        // when the database can't meaningfully express contradictions yet.
        if candidates.count < 2 {
            return candidates.compactMap { (fact, similarity) in
                similarity >= Self.pureSimilarityThreshold ? fact : nil
            }
        }

        // Step 3: LLM contradiction-check with a 5-second timeout.
        let indices = await runLLMCheckWithTimeout(newFactBody: newFactBody, candidates: candidates)
        let resolved = indices.compactMap { idx -> (SemanticFact, Double)? in
            guard candidates.indices.contains(idx) else { return nil }
            return candidates[idx]
        }

        // Step 4: cap by similarity score so a runaway response can't spam Feed.
        let capped = resolved.sorted { $0.1 > $1.1 }.prefix(Self.maxContradictionsPerWrite)
        return capped.map { $0.0 }
    }

    /// Races the LLM call against a `llmTimeoutSeconds` timer. On timeout, the
    /// LLM task is cancelled and a single fallback contradiction is returned
    /// IF the top shortlist entry's similarity is at least
    /// `llmTimeoutFallbackThreshold`. Empty array on any other failure.
    private func runLLMCheckWithTimeout(
        newFactBody: String,
        candidates: [(SemanticFact, Double)]
    ) async -> [Int] {
        let userMessage = ContradictionPrompts.buildUserMessage(
            newFactBody: newFactBody,
            candidates: candidates.map(\.0)
        )
        let systemPrompt = ContradictionPrompts.contradictionSystemPrompt
        let client = self.client

        return await withTaskGroup(of: RaceResult.self) { group in
            group.addTask {
                do {
                    let response = try await client.complete(
                        model: .balanced,
                        systemPrompt: systemPrompt,
                        messages: [LLMMessage(role: .user, text: userMessage)],
                        tools: nil
                    )
                    return .response(.success(ContradictionPrompts.parseIndices(response.text)))
                } catch {
                    return .response(.failure(error))
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(Self.llmTimeoutSeconds * 1_000_000_000))
                return .timeout
            }

            // Whichever task finishes first wins; cancel the rest.
            for await result in group {
                group.cancelAll()
                switch result {
                case .response(.success(let indices)):
                    return indices
                case .response(.failure(let error)):
                    print("[lifecycle] contradiction LLM call failed: \(error)")
                    return []
                case .timeout:
                    if let top = candidates.first, top.1 >= Self.llmTimeoutFallbackThreshold {
                        print("[lifecycle] contradiction LLM call timed out; using top-1 fallback (sim=\(top.1))")
                        return [0]
                    }
                    print("[lifecycle] contradiction LLM call timed out; no high-confidence fallback")
                    return []
                }
            }
            return []
        }
    }

    private enum RaceResult: Sendable {
        case response(Result<[Int], Error>)
        case timeout
    }
}
