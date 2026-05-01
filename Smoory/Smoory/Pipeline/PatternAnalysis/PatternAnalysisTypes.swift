import Foundation

struct PatternAnalysis: Codable, Sendable, Hashable {
    let analyzedAt: Date
    let weekStartedAt: Date
    let weekEndedAt: Date
    let stats: WeekStats
    let observations: [PatternObservation]
    let durableInsights: [DurableInsight]
}

struct WeekStats: Codable, Sendable, Hashable {
    let totalReminders: Int
    let completedReminders: Int
    let skippedReminders: Int
    let postponedReminders: Int
    let dayReviewsCompleted: Int
    let avgUserResponseTime: TimeInterval?   // average from notification to user action
    let mostDeferredAction: String?           // content of the action with highest deferralCount, if any
}

struct PatternObservation: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let observation: String
    let kind: ObservationKind
    let evidence: String

    enum ObservationKind: String, Codable, Sendable, Hashable {
        case completion
        case deferral
        case timing
        case absence
        case rhythm
    }

    init(id: UUID = UUID(), observation: String, kind: ObservationKind, evidence: String) {
        self.id = id
        self.observation = observation
        self.kind = kind
        self.evidence = evidence
    }
}

struct DurableInsight: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    let factText: String
    let confidence: Double
    let derivedFrom: [UUID]   // observation IDs supporting this insight

    init(id: UUID = UUID(), factText: String, confidence: Double, derivedFrom: [UUID]) {
        self.id = id
        self.factText = factText
        self.confidence = confidence
        self.derivedFrom = derivedFrom
    }
}

// MARK: - Wire format (LLM JSON shape)

/// What the LLM emits. derivedFromObservationIndices are 0-based positions into the
/// observations array; the analyzer maps them to UUIDs after decode.
struct PatternAnalysisPayload: Codable {
    let observations: [PatternObservationWire]
    let durableInsights: [DurableInsightWire]
}

struct PatternObservationWire: Codable {
    let observation: String
    let kind: String   // raw enum string
    let evidence: String
}

struct DurableInsightWire: Codable {
    let factText: String
    let confidence: Double
    let derivedFromObservationIndices: [Int]
}
