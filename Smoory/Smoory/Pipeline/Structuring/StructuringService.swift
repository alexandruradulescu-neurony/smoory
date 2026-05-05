import Foundation
import SwiftData

/// Runs the structuring-layer fast-tier LLM call after each chat turn and persists candidates.
/// Provider is whatever AIProviderStore points to (Anthropic Haiku or DeepSeek chat).
/// Best-effort: any failure is logged and silently swallowed; never disrupts chat.
@MainActor
final class StructuringService {
    private let client: LLMClient
    private let modelContainer: ModelContainer

    private static let confidenceFloor: Double = 0.5

    init(client: LLMClient, modelContainer: ModelContainer) {
        self.client = client
        self.modelContainer = modelContainer
    }

    func extract(
        userMessage: String,
        recentTurns: [String],
        chatSessionID: UUID,
        sourceTurnID: UUID?,
        alreadyHandled: StructuringPrompt.AlreadyHandled
    ) async {
        let trimmed = userMessage.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let snapshot = await snapshotExistingEntities()
        let userPrompt = StructuringPrompt.assembleUserMessage(
            userMessage: trimmed,
            recentTurns: recentTurns,
            snapshot: snapshot,
            alreadyHandled: alreadyHandled
        )

        let response: LLMResponse
        do {
            response = try await client.complete(
                model: .fast,
                systemPrompt: StructuringPrompt.systemPrompt,
                messages: [LLMMessage(role: .user, text: userPrompt)],
                tools: []
            )
        } catch {
            print("[structuring] fast-tier call failed: \(error)")
            return
        }

        guard let parsed = StructuringPrompt.parse(response.text) else {
            StructuringFailureCounter.shared.increment()
            print("[structuring] could not parse response as JSON. Raw first 200: \(response.text.prefix(200))")
            return
        }

        // Defensive filter — the structuring LLM is told via the prompt to skip
        // already-handled items, but it sometimes re-emits them anyway. Drop matches
        // client-side so chat-created todos/facts can't reappear in the Feed.
        let handledTodos = Set(alreadyHandled.createdTodoTitles.map(Self.normalize))
        let handledFacts = Set(alreadyHandled.writtenFactBodies.map(Self.normalize))

        let kept = parsed.filter { p in
            guard p.confidence >= Self.confidenceFloor else { return false }
            let normContent = Self.normalize(p.content)
            let normPhrase = Self.normalize(p.userPhrase)
            switch p.type {
            case .todo:
                // Hard suppression when create_todo fired this turn — the title-based
                // dedup misses cases where the assistant titles a todo "Call Maria"
                // while structuring extracts "User needs to call Maria tomorrow". Both
                // refer to the same intent; let the tool be the source of truth.
                if alreadyHandled.anyTodoToolFired { return false }
                return !handledTodos.contains(normContent)
                    && !handledTodos.contains(normPhrase)
            case .fact:
                // 4.4: per-turn structuring no longer emits .fact candidates;
                // batched extraction owns that path. Defensive filter — if the
                // LLM ignores the prompt instruction and emits one anyway, drop
                // it client-side rather than spam Feed with premature commits.
                return false
            default:
                return true
            }
        }
        if kept.isEmpty {
            return
        }

        let extractingModel = AIProviderStore.current().modelID(for: .fast)

        await persistCandidates(
            kept,
            chatSessionID: chatSessionID,
            sourceTurnID: sourceTurnID,
            extractingModel: extractingModel
        )
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func snapshotExistingEntities() async -> StructuringPrompt.Snapshot {
        let context = ModelContext(modelContainer)

        let roles = (try? context.fetch(FetchDescriptor<Role>())) ?? []
        let goals = (try? context.fetch(FetchDescriptor<Goal>())) ?? []
        let projects = (try? context.fetch(FetchDescriptor<Project>())) ?? []
        let persons = (try? context.fetch(FetchDescriptor<Person>())) ?? []

        return StructuringPrompt.Snapshot(
            roleNames: roles.map(\.name).filter { !$0.isEmpty },
            goalTitles: goals.map(\.title).filter { !$0.isEmpty },
            projectTitles: projects.map(\.title).filter { !$0.isEmpty },
            personNames: persons.map(\.displayName).filter { !$0.isEmpty }
        )
    }

    private func persistCandidates(
        _ parsed: [ParsedCandidate],
        chatSessionID: UUID,
        sourceTurnID: UUID?,
        extractingModel: String
    ) async {
        let context = ModelContext(modelContainer)

        // Dedup against existing pending candidates: skip incoming whose normalized
        // (type, content) matches a row already waiting in the Feed OR previously
        // rejected. Stops the LLM re-emitting the same proposal across turns and
        // — critically — stops a candidate the user already said no to from
        // resurfacing every time the structuring layer hears similar phrasing.
        // Confirmed / auto-applied rows are NOT in the seen set: those represent
        // information that's already been applied, and a fresh user statement of
        // similar content might warrant a refinement candidate (handled by the
        // restructurer, not the structuring layer).
        var seen = Set<String>()
        let blockingStatusRaws: [Int] = [
            CandidateStatus.pending.rawValue,
            CandidateStatus.rejected.rawValue
        ]
        let blockingDescriptor = FetchDescriptor<CandidateWrite>(
            predicate: #Predicate<CandidateWrite> { blockingStatusRaws.contains($0.statusRaw) }
        )
        if let existing = try? context.fetch(blockingDescriptor) {
            for row in existing {
                seen.insert(Self.dedupeKey(typeRaw: row.typeRaw, content: row.effectiveContent))
            }
        }

        var inserted = 0
        var skipped = 0
        for p in parsed {
            let key = Self.dedupeKey(typeRaw: p.type.rawValue, content: p.content)
            if seen.contains(key) {
                skipped += 1
                continue
            }
            seen.insert(key)
            let row = CandidateWrite()
            row.type = p.type
            row.content = p.content
            row.proposedTitle = p.title
            row.confidence = p.confidence
            row.userPhrase = p.userPhrase
            row.expiresAt = p.expiresAt
            row.sourceSessionID = chatSessionID
            row.sourceTurnID = sourceTurnID
            row.extractingModel = extractingModel
            row.status = .pending
            context.insert(row)
            inserted += 1
        }
        do {
            try context.save()
            if skipped > 0 {
                print("[structuring] persisted \(inserted) candidate(s); skipped \(skipped) duplicate(s)")
            } else {
                print("[structuring] persisted \(inserted) candidate(s)")
            }
        } catch {
            print("[structuring] save failed: \(error)")
        }
    }

    /// Composite key for candidate dedup. Pairs the type raw value with the same
    /// body normalization used for hema fact dedup so the two layers agree on what
    /// "same content" means.
    static func dedupeKey(typeRaw: Int, content: String) -> String {
        "\(typeRaw):\(HemaService.normalizeBody(content))"
    }

    /// Retroactive cleanup of duplicate pending CandidateWrite rows. Within each
    /// (type, normalized content) group the oldest pending row survives; newer
    /// duplicates are flipped to .rejected with reason "duplicate of <id> (auto)".
    /// Confirmed, auto-applied, and previously rejected rows are not touched.
    @MainActor
    static func dedupePendingCandidates(in modelContainer: ModelContainer) throws -> CandidateDedupeReport {
        var lines: [String] = ["---- DEDUPE PENDING CANDIDATES ----"]
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<CandidateWrite>(
            predicate: #Predicate<CandidateWrite> { $0.statusRaw == 0 }
        )
        let pending = try context.fetch(descriptor).sorted { $0.createdAt < $1.createdAt }
        lines.append("Loaded \(pending.count) pending candidate(s).")

        var canonical: [String: CandidateWrite] = [:]
        var rejected = 0
        for cand in pending {
            let key = dedupeKey(typeRaw: cand.typeRaw, content: cand.effectiveContent)
            if let keep = canonical[key] {
                cand.status = .rejected
                cand.reviewedAt = Date()
                cand.rejectionReason = "duplicate of \(keep.id) (auto)"
                rejected += 1
                lines.append("rejected \(cand.id) → kept \(keep.id) [type=\(cand.typeRaw)]")
            } else {
                canonical[key] = cand
            }
        }
        try context.save()
        let remaining = pending.count - rejected
        lines.append("---- DONE: rejected \(rejected); \(remaining) pending remain ----")
        return CandidateDedupeReport(
            duplicatesRejected: rejected,
            remainingPending: remaining,
            lines: lines
        )
    }
}

struct CandidateDedupeReport: Sendable {
    let duplicatesRejected: Int
    let remainingPending: Int
    let lines: [String]

    var summary: String {
        "Rejected \(duplicatesRejected) duplicate candidate(s). \(remainingPending) pending remain."
    }
}
