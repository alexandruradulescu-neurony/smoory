import Foundation
import SwiftData

@Model
final class CandidateWrite {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var typeRaw: Int = 0                    // CandidateType raw
    var content: String = ""                // record-ready statement from the structuring LLM
    var editedContent: String = ""          // user's optional edit pre-confirm
    var confidence: Double = 0
    var userPhrase: String = ""             // exact words that triggered
    var expiresAt: Date?                    // for time-bounded (availability) candidates
    var statusRaw: Int = 0                  // CandidateStatus raw
    var sourceTurnID: UUID?                 // hema turn id (nullable in v1)
    var sourceSessionID: UUID?              // hema chat session id
    var extractingModel: String = ""        // model id that produced this candidate
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
}
