import Foundation

/// Operation type for a `.factRewrite` CandidateWrite (4.5). Each value
/// describes what the day-end restructurer is proposing to do with one or
/// more existing facts.
enum FactRewriteOp: String, Codable, Sendable {
    /// Edit a single fact's body in place (write new + supersede old).
    case refine
    /// Collapse 2-3 facts about the same entity into one consolidated fact.
    case merge
    /// One existing fact really packs 2-3 distinct ideas; expand into N.
    case split
    /// Today's evidence makes the fact false. Effectively a supersession
    /// proposed by the restructurer rather than the contradiction detector.
    case contradict
    /// Mark the fact non-durable. On confirm, sets status = .archived
    /// (the lifecycle state added by 4.3 schema).
    case archive
}

/// Wire-format payload encoded into `CandidateWrite.content` for `.factRewrite`
/// rows. One unified shape covers all 5 operations — different fields are
/// populated per op (validated client-side at decode).
///
/// Display fields (`oldBodies`) are duplicated from the underlying SemanticFact
/// rows so the row UI renders correctly even if the user later edits or
/// deletes those facts. The candidate is the audit trail of the proposal,
/// not a live view.
struct FactRewriteContent: Codable, Sendable {
    let op: FactRewriteOp
    /// IDs of the fact(s) the operation acts on. Single element for refine,
    /// split, contradict, archive. Multiple elements (2-3) for merge.
    let oldFactIDs: [UUID]
    /// Display copies of `oldFactIDs`'s bodies, captured at proposal time.
    let oldBodies: [String]
    /// New body or bodies the operation proposes. Single element for refine,
    /// merge, contradict. Multiple (2-3) for split. Empty for archive.
    let newBodies: [String]
    /// Optional rationale (archive) or LLM explanation (any op). Surfaced in
    /// the candidate row for transparency about WHY the restructurer is
    /// proposing this change.
    let reason: String?
    /// Captured creation timestamps of the operation's input facts. Used by
    /// the row UI's "saved N days ago" labels.
    let oldCreatedAts: [Date]
}
