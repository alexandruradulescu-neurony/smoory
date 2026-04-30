import Foundation
import SwiftData

/// Type-dispatched entity creation when a CandidateWrite is confirmed.
/// Each branch sets `candidate.resultEntityID` so the audit trail is explicit.
@MainActor
enum CandidateAcceptor {
    static func accept(
        candidate: CandidateWrite,
        modelContainer: ModelContainer,
        hema: HemaService
    ) async throws {
        let context = ModelContext(modelContainer)
        let body = candidate.effectiveContent

        switch candidate.type {
        case .goal:
            let goal = Goal()
            goal.title = body
            context.insert(goal)
            try context.save()
            candidate.resultEntityID = goal.id

        case .project:
            let project = Project()
            project.title = body
            context.insert(project)
            try context.save()
            candidate.resultEntityID = project.id

        case .todo:
            let todo = try CreateTodoTool.performAction(
                title: body,
                source: .userQuickadd,
                modelContainer: modelContainer
            )
            candidate.resultEntityID = todo.id

        case .person:
            let person = Person()
            person.displayName = body
            context.insert(person)
            try context.save()
            candidate.resultEntityID = person.id

        case .infrastructure:
            let infra = Infrastructure()
            infra.name = body
            context.insert(infra)
            try context.save()
            candidate.resultEntityID = infra.id

        case .availability:
            // Stopgap (see PHASE_3_NOTES.md): no Availability/OffPeriod entity yet.
            // Write as a fact tagged "availability"; expiresAt carries the time bound.
            let fact = SemanticFact(
                id: UUID(),
                body: body,
                tags: ["availability"],
                entitiesReferenced: [],
                confidence: candidate.confidence,
                userConfirmed: true,
                createdAt: Date(),
                expiresAt: candidate.expiresAt,
                supersededBy: nil,
                provenanceJSON: makeProvenanceJSON(
                    sourceKind: "structuring_layer",
                    candidate: candidate
                ),
                vector: nil,
                isPrivate: false
            )
            try await hema.writeFact(fact)
            candidate.resultEntityID = fact.id

        case .toneObservation:
            // Stopgap (see PHASE_4_NOTES.md): tag-as-tone fact until ToneProfile flow lands.
            let fact = SemanticFact(
                id: UUID(),
                body: body,
                tags: ["tone"],
                entitiesReferenced: [],
                confidence: candidate.confidence,
                userConfirmed: true,
                createdAt: Date(),
                expiresAt: nil,
                supersededBy: nil,
                provenanceJSON: makeProvenanceJSON(
                    sourceKind: "structuring_layer",
                    candidate: candidate
                ),
                vector: nil,
                isPrivate: false
            )
            try await hema.writeFact(fact)
            candidate.resultEntityID = fact.id

        case .fact:
            let fact = SemanticFact(
                id: UUID(),
                body: body,
                tags: [],
                entitiesReferenced: [],
                confidence: candidate.confidence,
                userConfirmed: true,
                createdAt: Date(),
                expiresAt: candidate.expiresAt,
                supersededBy: nil,
                provenanceJSON: makeProvenanceJSON(
                    sourceKind: "structuring_layer",
                    candidate: candidate
                ),
                vector: nil,
                isPrivate: false
            )
            try await hema.writeFact(fact)
            candidate.resultEntityID = fact.id
        }

        candidate.status = .confirmed
        candidate.reviewedAt = Date()
        try context.save()
    }

    static func reject(
        candidate: CandidateWrite,
        reason: String? = nil,
        modelContainer: ModelContainer
    ) throws {
        let context = ModelContext(modelContainer)
        // Find the entity in the new context — the @Bindable reference may be from another context.
        let candidateID = candidate.id
        let descriptor = FetchDescriptor<CandidateWrite>(predicate: #Predicate { $0.id == candidateID })
        guard let stored = try context.fetch(descriptor).first else { return }
        stored.status = .rejected
        stored.reviewedAt = Date()
        stored.rejectionReason = reason
        try context.save()
    }

    private static func makeProvenanceJSON(sourceKind: String, candidate: CandidateWrite) -> String {
        let extractedAt = Date().formatted(.iso8601)
        let sessionPart = candidate.sourceSessionID
            .map { #""source_session_id":"\#($0.uuidString)","# }
            ?? ""
        return #"{"source_kind":"\#(sourceKind)",\#(sessionPart)"extracted_at":"\#(extractedAt)","extracting_model":"claude-haiku-4-5","confidence":\#(candidate.confidence),"user_confirmed":true,"user_phrase":"\#(escape(candidate.userPhrase))"}"#
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
