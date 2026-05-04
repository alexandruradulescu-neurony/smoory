import Foundation
import SwiftData

/// Wire-format payload encoded into `CandidateWrite.content` for `.supersession`
/// rows. Both fact bodies and creation timestamps are duplicated alongside the
/// IDs so the row UI renders correctly even if the underlying SemanticFact
/// rows are later deleted (defensive — the candidate is the audit trail of
/// the supersession decision, not a live view).
struct SupersessionContent: Codable, Sendable {
    let newFactID: UUID
    let oldFactID: UUID
    let newFactBody: String
    let oldFactBody: String
    let newFactCreatedAt: Date
    let oldFactCreatedAt: Date
    let detectionConfidence: Double
}

/// Owner of `.supersession` CandidateWrite rows: builds them from a detected
/// contradiction pair, persists them, and provides the encode/decode helpers
/// the row view + CandidateAcceptor need to round-trip the payload.
@MainActor
enum SupersessionCandidateBuilder {
    /// Heuristic confidence on detected contradictions when the LLM doesn't
    /// emit per-pair confidences. Used as the candidate's `confidence` so the
    /// row UI's percent display ("90%") is loosely meaningful.
    private static let defaultDetectionConfidence: Double = 0.9

    /// Builds and persists a `.supersession` CandidateWrite for the given
    /// pair. Idempotent: if a candidate already exists for the same
    /// `(newFactID, oldFactID)` pair (in any status), this no-ops. Prevents
    /// Feed spam when contradiction detection runs again on the same content
    /// — re-asserting the same pair after the user has reviewed it once is
    /// noise.
    static func create(
        newFact: SemanticFact,
        oldFact: SemanticFact,
        detectionConfidence: Double = defaultDetectionConfidence,
        modelContainer: ModelContainer
    ) throws {
        let context = ModelContext(modelContainer)

        // Idempotency check. JSON-content predicate would require contains-string
        // matching; simpler to fetch all .supersession rows (low cardinality)
        // and compare in Swift.
        let supersessionRaw = CandidateType.supersession.rawValue
        let descriptor = FetchDescriptor<CandidateWrite>(
            predicate: #Predicate<CandidateWrite> { $0.typeRaw == supersessionRaw }
        )
        let existing = (try? context.fetch(descriptor)) ?? []
        let alreadyFlagged = existing.contains { row in
            guard let payload = decode(row.content) else { return false }
            return payload.newFactID == newFact.id && payload.oldFactID == oldFact.id
        }
        if alreadyFlagged { return }

        let payload = SupersessionContent(
            newFactID: newFact.id,
            oldFactID: oldFact.id,
            newFactBody: newFact.body,
            oldFactBody: oldFact.body,
            newFactCreatedAt: newFact.createdAt,
            oldFactCreatedAt: oldFact.createdAt,
            detectionConfidence: detectionConfidence
        )

        let row = CandidateWrite()
        row.type = .supersession
        row.content = encode(payload) ?? ""
        row.confidence = detectionConfidence
        row.status = .pending
        row.sourceKind = "contradiction_detector"
        // userPhrase, sourceSessionID, sourceTurnID, expiresAt: defaults are correct.
        context.insert(row)
        try context.save()
    }

    /// Fire-and-forget contradiction detection after a fact write. Used by
    /// `WriteMemoryFactTool` (silent assistant writes) and `CandidateAcceptor`
    /// (.fact / .availability / .toneObservation confirmations). Detection
    /// runs as a detached MainActor task so the calling chat or UI flow does
    /// not block on the detector's LLM call. On failure, the failure counter
    /// increments and the new fact stays in place.
    static func runDetectionAfterWrite(
        newFactID: UUID,
        newFactBody: String,
        hema: HemaService,
        modelContainer: ModelContainer
    ) {
        Task.detached { @MainActor in
            let detector = ContradictionDetector(hema: hema)
            do {
                let conflicts = try await detector.detect(
                    newFactBody: newFactBody,
                    excludingID: newFactID
                )
                guard !conflicts.isEmpty else { return }
                guard let newFact = try await hema.readFact(id: newFactID) else { return }
                for old in conflicts {
                    do {
                        try Self.create(
                            newFact: newFact,
                            oldFact: old,
                            modelContainer: modelContainer
                        )
                    } catch {
                        ContradictionDetectionFailureCounter.shared.increment()
                        print("[lifecycle] failed to persist supersession candidate for \(old.id): \(error)")
                    }
                }
            } catch {
                ContradictionDetectionFailureCounter.shared.increment()
                print("[lifecycle] contradiction detection failed: \(error)")
            }
        }
    }

    static func decode(_ json: String) -> SupersessionContent? {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SupersessionContent.self, from: data)
    }

    static func encode(_ content: SupersessionContent) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(content),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }
}
