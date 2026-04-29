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
    let metadataJSON: String?       // freeform JSON; opaque to hema
    let vector: [Float]?            // nil in 2.1a (no embedder yet)
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

enum HemaState {
    case loading
    case ready(HemaService)
    case failed(String)
}
