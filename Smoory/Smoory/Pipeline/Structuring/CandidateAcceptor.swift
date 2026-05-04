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
        // Re-fetch in this context so mutations land in the same context we save.
        // Mutating the @Bindable from FeedView's context and saving a different
        // context loses the status flip — the candidate stays Pending in the UI.
        let context = ModelContext(modelContainer)
        let candidateID = candidate.id
        let descriptor = FetchDescriptor<CandidateWrite>(predicate: #Predicate { $0.id == candidateID })
        guard let stored = try context.fetch(descriptor).first else { return }

        let body = stored.effectiveContent

        switch stored.type {
        case .goal:
            let goal = Goal()
            // Goals get a short label, not a third-person sentence (the structuring
            // prompt emits "title" alongside "content" for goal/project candidates;
            // CandidateWrite.derivedTitle picks proposedTitle when set, else strips
            // sentence prefixes from `body` as a fallback).
            goal.title = stored.derivedTitle
            goal.details = body
            context.insert(goal)
            stored.resultEntityID = goal.id

        case .project:
            let project = Project()
            project.title = stored.derivedTitle
            project.details = body
            context.insert(project)
            stored.resultEntityID = project.id

        case .todo:
            let todo = try CreateTodoTool.performAction(
                title: body,
                source: .userQuickadd,
                modelContainer: modelContainer
            )
            stored.resultEntityID = todo.id

        case .person:
            let person = Person()
            person.displayName = body
            context.insert(person)
            stored.resultEntityID = person.id

        case .infrastructure:
            let infra = Infrastructure()
            infra.name = body
            context.insert(infra)
            stored.resultEntityID = infra.id

        case .availability:
            // Stopgap (see PHASE_3_NOTES.md): no Availability/OffPeriod entity yet.
            // Write as a fact tagged "availability"; expiresAt carries the time bound.
            let fact = SemanticFact(
                id: UUID(),
                body: body,
                tags: ["availability"],
                entitiesReferenced: [],
                confidence: stored.confidence,
                userConfirmed: true,
                createdAt: Date(),
                expiresAt: stored.expiresAt,
                supersededBy: nil,
                provenanceJSON: makeProvenanceJSON(
                    sourceKind: stored.sourceKind.isEmpty ? "structuring_layer" : stored.sourceKind,
                    candidate: stored
                ),
                vector: nil,
                isPrivate: false
            )
            // writeFact returns the surviving id — may differ from fact.id when dedup
            // matched an existing row. Use it for the audit reference.
            stored.resultEntityID = try await hema.writeFact(fact)

        case .toneObservation:
            // Stopgap (see PHASE_4_NOTES.md): tag-as-tone fact until ToneProfile flow lands.
            let fact = SemanticFact(
                id: UUID(),
                body: body,
                tags: ["tone"],
                entitiesReferenced: [],
                confidence: stored.confidence,
                userConfirmed: true,
                createdAt: Date(),
                expiresAt: nil,
                supersededBy: nil,
                provenanceJSON: makeProvenanceJSON(
                    sourceKind: stored.sourceKind.isEmpty ? "structuring_layer" : stored.sourceKind,
                    candidate: stored
                ),
                vector: nil,
                isPrivate: false
            )
            stored.resultEntityID = try await hema.writeFact(fact)

        case .fact:
            let fact = SemanticFact(
                id: UUID(),
                body: body,
                tags: [],
                entitiesReferenced: [],
                confidence: stored.confidence,
                userConfirmed: true,
                createdAt: Date(),
                expiresAt: stored.expiresAt,
                supersededBy: nil,
                provenanceJSON: makeProvenanceJSON(
                    sourceKind: stored.sourceKind.isEmpty ? "structuring_layer" : stored.sourceKind,
                    candidate: stored
                ),
                vector: nil,
                isPrivate: false
            )
            stored.resultEntityID = try await hema.writeFact(fact)
        }

        stored.status = .confirmed
        stored.reviewedAt = Date()
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
        let confirmedAt = (candidate.reviewedAt ?? Date()).formatted(.iso8601)
        let sessionPart = candidate.sourceSessionID
            .map { #""source_session_id":"\#($0.uuidString)","# }
            ?? ""
        let extractingModel = candidate.extractingModel.isEmpty
            ? AIProviderStore.current().modelID(for: .fast)
            : candidate.extractingModel
        return #"{"source_kind":"\#(sourceKind)",\#(sessionPart)"extracted_at":"\#(extractedAt)","extracting_model":"\#(escape(extractingModel))","confidence":\#(candidate.confidence),"user_confirmed":true,"user_confirmed_at":"\#(confirmedAt)","user_phrase":"\#(escape(candidate.userPhrase))"}"#
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
