import Foundation
import SwiftData

/// Max lookback window across all BatchedFactExtractor triggers (appLaunchGap,
/// scenePhaseBackground, manualDebug all read 24h of turns; idlePause /
/// dayReviewPiggyback read shorter windows). Once a rejected `.fact` candidate
/// is older than this, no extraction trigger can re-propose its body, so the
/// row's tombstone job is done and `pruneStaleRejectedFacts` deletes it.
private let factCandidateRejectionTombstoneTTL: TimeInterval = 86_400

@Model
final class CandidateWrite {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var typeRaw: Int = 0                    // CandidateType raw
    var content: String = ""                // record-ready statement from the structuring LLM
    var editedContent: String = ""          // user's optional edit pre-confirm
    var proposedTitle: String = ""          // short label for goal/project entities; empty for other types
    var confidence: Double = 0
    var userPhrase: String = ""             // exact words that triggered
    var expiresAt: Date?                    // for time-bounded (availability) candidates
    var statusRaw: Int = 0                  // CandidateStatus raw
    var sourceTurnID: UUID?                 // hema turn id (nullable in v1)
    var sourceSessionID: UUID?              // hema chat session id
    var extractingModel: String = ""        // model id that produced this candidate
    var sourceKind: String = "structuring_layer"  // producer identity — "structuring_layer" or "week_review_pattern_analysis"; threads into provenance JSON on confirm
    var reviewedAt: Date?
    var rejectionReason: String?
    var resultEntityID: UUID?               // entity created on confirm

    init() {}
}

extension CandidateWrite {
    var type: CandidateType {
        get { CandidateType(rawValue: typeRaw) ?? .fact }
        set { typeRaw = newValue.rawValue }
    }

    var status: CandidateStatus {
        get { CandidateStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    /// Body to write — user's edited content if present, else the structuring LLM's original.
    var effectiveContent: String {
        let trimmed = editedContent.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? content : trimmed
    }

    /// Short label for goal/project entities. Returns the LLM-proposed title when present;
    /// otherwise derives a short title from `effectiveContent` via heuristic prefix/suffix
    /// stripping. Used by CandidateAcceptor when creating Goal/Project records so titles
    /// stay readable rather than being full third-person sentences.
    var derivedTitle: String {
        let proposed = proposedTitle.trimmingCharacters(in: .whitespaces)
        if !proposed.isEmpty { return proposed }
        return Self.shortenSentence(effectiveContent)
    }

    /// Hard-deletes rejected `.fact` candidates older than the max extraction
    /// window (24h). After that age, no extraction trigger can re-propose the
    /// same body — the tombstone job is done. Prevents long-term accumulation
    /// of rejected rows in the Feed and SwiftData store. Called from
    /// `SmooryApp`'s launch `.task` before hema-driven gap extraction fires.
    @MainActor
    static func pruneStaleRejectedFacts(modelContainer: ModelContainer) {
        let context = ModelContext(modelContainer)
        let factRaw = CandidateType.fact.rawValue
        let rejectedRaw = CandidateStatus.rejected.rawValue
        let descriptor = FetchDescriptor<CandidateWrite>(
            predicate: #Predicate<CandidateWrite> {
                $0.typeRaw == factRaw && $0.statusRaw == rejectedRaw
            }
        )
        guard let rows = try? context.fetch(descriptor), !rows.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-factCandidateRejectionTombstoneTTL)
        var deleted = 0
        for row in rows where row.createdAt < cutoff {
            context.delete(row)
            deleted += 1
        }
        guard deleted > 0 else { return }
        do {
            try context.save()
            print("[candidate-write] pruned \(deleted) stale rejected .fact candidate(s)")
        } catch {
            print("[candidate-write] prune save failed: \(error)")
        }
    }

    /// Heuristic fallback: drop common third-person prefixes ("User wants to ...") and
    /// known trailing time qualifiers, then truncate. Used only when the LLM didn't
    /// supply `proposedTitle` (older candidates, or model regression).
    static func shortenSentence(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "The user wants to ",
            "The user is ",
            "The user has ",
            "The user ",
            "User wants to ",
            "User is ",
            "User has ",
            "User ",
        ]
        for prefix in prefixes where t.hasPrefix(prefix) {
            t = String(t.dropFirst(prefix.count))
            break
        }
        if let firstChar = t.first {
            t = firstChar.uppercased() + t.dropFirst()
        }
        // Drop trailing period and clip at 80 chars at a word boundary.
        if t.hasSuffix(".") { t = String(t.dropLast()) }
        if t.count > 80 {
            let cap = t.index(t.startIndex, offsetBy: 80)
            if let space = t[..<cap].lastIndex(of: " ") {
                t = String(t[..<space])
            } else {
                t = String(t[..<cap])
            }
        }
        return t
    }
}
