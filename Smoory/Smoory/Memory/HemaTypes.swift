import Foundation

struct CompactMemory: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, Codable, CaseIterable, Hashable {
        case overall
        case recent
        case today
    }

    let id: UUID
    let kind: Kind
    let body: String
    let wordCount: Int
    let generatedAt: Date
    let supersededAt: Date?         // nil = currently active
    let generatingModel: String?    // e.g. "claude-sonnet-4-6"
}

struct MemoryTurn: Identifiable, Hashable, Sendable {
    enum Role: String, Sendable, Codable, Hashable {
        case user
        case assistant
    }

    let id: UUID
    let createdAt: Date
    let chatSessionID: UUID
    let role: Role
    let content: String
    let vector: [Float]?            // populated when an embedder is configured
}

/// Lifecycle state of a semantic fact (4.3). Refines the existing supersededBy
/// column. `.active` rows are eligible for retrieval; `.superseded` rows stay
/// in the database for audit trail but are excluded from default queries;
/// `.archived` is reserved for future user-initiated archival and unused in 4.3.
enum FactStatus: String, Codable, Sendable, CaseIterable {
    case active
    case superseded
    case archived
}

struct SemanticFact: Identifiable, Hashable, Sendable {
    let id: UUID
    let body: String
    let tags: [String]
    let entitiesReferenced: [EntityReference]   // Phase 1 type, reused
    let confidence: Double
    let userConfirmed: Bool
    let createdAt: Date
    let expiresAt: Date?
    let supersededBy: UUID?
    let provenanceJSON: String?     // shape per MEMORY.md "Provenance" section
    let vector: [Float]?            // nil in 2.1a
    let isPrivate: Bool             // per-fact private flag — never sent to LLM by default
    let status: FactStatus          // 4.3 lifecycle state, default .active

    /// Explicit init with a default for `status` so existing call sites that
    /// pre-date 4.3 (and don't pass status) still compile. Hema's decoder is
    /// the only path that needs to pass status explicitly — every other writer
    /// creates active facts.
    init(
        id: UUID,
        body: String,
        tags: [String],
        entitiesReferenced: [EntityReference],
        confidence: Double,
        userConfirmed: Bool,
        createdAt: Date,
        expiresAt: Date?,
        supersededBy: UUID?,
        provenanceJSON: String?,
        vector: [Float]?,
        isPrivate: Bool,
        status: FactStatus = .active
    ) {
        self.id = id
        self.body = body
        self.tags = tags
        self.entitiesReferenced = entitiesReferenced
        self.confidence = confidence
        self.userConfirmed = userConfirmed
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.supersededBy = supersededBy
        self.provenanceJSON = provenanceJSON
        self.vector = vector
        self.isPrivate = isPrivate
        self.status = status
    }
}

struct FactFilter: Sendable, Hashable {
    var tags: [String]? = nil
    var entities: [EntityReference]? = nil
    var includeExpired: Bool = false
    var includeSuperseded: Bool = false
    var includePrivate: Bool = false       // listings exclude private by default; explicit opt-in for inspection UI
    var minConfidence: Double? = nil
    var createdSince: Date? = nil
    var createdBefore: Date? = nil
}

enum HemaServiceError: Error {
    case decoding(String)
    case databaseInit(Error)
    case migration(Error)
}

struct SelfTestReport: Sendable {
    let passed: Bool
    let lines: [String]
}

struct DedupeReport: Sendable {
    let exactRemoved: Int
    let semanticRemoved: Int
    let remainingFacts: Int
    let lines: [String]

    var summary: String {
        "Removed \(exactRemoved) exact dupe(s), \(semanticRemoved) semantic near-dupe(s). \(remainingFacts) fact(s) remain."
    }
}

enum HemaState: Sendable {
    case loading
    case ready(HemaService)
    case failed(String)
}
