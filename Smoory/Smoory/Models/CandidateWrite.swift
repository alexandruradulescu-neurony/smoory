import Foundation
import SwiftData

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
