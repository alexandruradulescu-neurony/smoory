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
            // 4.8c — backing entity is now UserListItem inserted into the auto-managed
            // "Todos" list. CreateTodoTool.performAction returns the new item.
            let item = try CreateTodoTool.performAction(
                title: body,
                source: .userQuickadd,
                modelContainer: modelContainer
            )
            stored.resultEntityID = item.id

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
            // 4.9 — replaces the Phase 3 stopgap that wrote tag-availability facts.
            // Now creates an OffPeriod entity. start defaults to today's start-of-day
            // (the user said "I'll be off …" at confirm time); end uses the
            // candidate's expiresAt when set, else mirrors start (single-day off).
            let cal = Calendar.current
            let startDay = cal.startOfDay(for: Date())
            let endDay: Date = stored.expiresAt.map { cal.startOfDay(for: $0) } ?? startDay
            let off = OffPeriod()
            off.startDate = startDay
            off.endDate = endDay >= startDay ? endDay : startDay
            off.kind = .personal
            off.notes = body
            off.sourceCandidateID = stored.id
            let now = Date()
            off.createdAt = now
            off.updatedAt = now
            context.insert(off)
            stored.resultEntityID = off.id

            // Fire-and-forget: surface conflicting todos / calendar events as feed
            // cards once the OffPeriod row is durable. Generator opens a fresh
            // ModelContext so it doesn't race the save below.
            let generator = OffPeriodProposalGenerator(modelContainer: modelContainer)
            let offID = off.id
            Task { @MainActor in
                await generator.proposeConflicts(forOffPeriodID: offID)
            }

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
            let writtenID = try await hema.writeFact(fact)
            stored.resultEntityID = writtenID
            SupersessionCandidateBuilder.runDetectionAfterWrite(
                newFactID: writtenID,
                newFactBody: fact.body,
                hema: hema,
                modelContainer: modelContainer
            )

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
            let writtenID = try await hema.writeFact(fact)
            stored.resultEntityID = writtenID
            SupersessionCandidateBuilder.runDetectionAfterWrite(
                newFactID: writtenID,
                newFactBody: fact.body,
                hema: hema,
                modelContainer: modelContainer
            )

        case .supersession:
            // 4.3 — user confirmed the contradiction. Mark the old fact superseded,
            // linking it to the new fact's id. Decoded payload preserves both ids
            // even if the underlying SemanticFact rows have since been edited.
            guard let payload = SupersessionCandidateBuilder.decode(stored.content) else {
                stored.status = .rejected
                stored.reviewedAt = Date()
                stored.rejectionReason = "supersession content failed to decode"
                try context.save()
                return
            }
            try await hema.supersedeFact(
                oldFactID: payload.oldFactID,
                newFactID: payload.newFactID
            )
            // The "result" of a supersession confirmation is the old fact's id —
            // that's what changed state.
            stored.resultEntityID = payload.oldFactID

        case .factRewrite:
            // 4.5 — user confirmed a refine / merge / split / contradict / archive
            // operation. Decoded payload determines the path.
            guard let payload = FactRestructurer.decode(stored.content) else {
                stored.status = .rejected
                stored.reviewedAt = Date()
                stored.rejectionReason = "factRewrite content failed to decode"
                try context.save()
                return
            }
            try await Self.applyFactRewrite(payload: payload, hema: hema)
            // resultEntityID points at the first old fact that changed state —
            // best-effort audit link (split affects one old → many new; merge
            // many → one; the first old is the most useful single referent).
            stored.resultEntityID = payload.oldFactIDs.first
        }

        stored.status = .confirmed
        stored.reviewedAt = Date()
        try context.save()
    }

    /// 4.5 — applies a confirmed FactRewriteContent payload to hema. Each op
    /// has a distinct lifecycle effect (write new + supersede old(s),
    /// archive only, etc.). Failures throw and abort the candidate confirm
    /// path, leaving the old fact unchanged.
    private static func applyFactRewrite(
        payload: FactRewriteContent,
        hema: HemaService
    ) async throws {
        switch payload.op {
        case .refine, .contradict, .merge:
            // Single new body replaces N old facts (N=1 for refine/contradict,
            // N=2-3 for merge). Write the new fact, supersede each old.
            guard let newBody = payload.newBodies.first, !newBody.isEmpty else { return }
            let newFact = SemanticFact(
                id: UUID(),
                body: newBody,
                tags: [],
                entitiesReferenced: [],
                confidence: 0.9,
                userConfirmed: true,
                createdAt: Date(),
                expiresAt: nil,
                supersededBy: nil,
                provenanceJSON: makeRewriteProvenance(payload: payload),
                vector: nil,
                isPrivate: false
            )
            let writtenID = try await hema.writeFact(newFact)
            for oldID in payload.oldFactIDs {
                try await hema.supersedeFact(oldFactID: oldID, newFactID: writtenID)
            }

        case .split:
            // Single old fact → multiple new facts. Each new fact stands on
            // its own; the old's superseded_by points at the first new fact
            // (best-effort single-UUID audit link, since the schema can't
            // express one-to-many supersession).
            guard let oldID = payload.oldFactIDs.first else { return }
            var newIDs: [UUID] = []
            for newBody in payload.newBodies where !newBody.isEmpty {
                let newFact = SemanticFact(
                    id: UUID(),
                    body: newBody,
                    tags: [],
                    entitiesReferenced: [],
                    confidence: 0.9,
                    userConfirmed: true,
                    createdAt: Date(),
                    expiresAt: nil,
                    supersededBy: nil,
                    provenanceJSON: makeRewriteProvenance(payload: payload),
                    vector: nil,
                    isPrivate: false
                )
                let id = try await hema.writeFact(newFact)
                newIDs.append(id)
            }
            if let firstNew = newIDs.first {
                try await hema.supersedeFact(oldFactID: oldID, newFactID: firstNew)
            }

        case .archive:
            // No new fact written. Just mark the old archived.
            guard let oldID = payload.oldFactIDs.first else { return }
            try await hema.archiveFact(id: oldID)
        }
    }

    /// Provenance JSON for facts produced by 4.5 restructurer ops.
    /// Threads the rationale into the new fact's audit trail so future
    /// retrieval / inspection can see why it was written.
    private static func makeRewriteProvenance(payload: FactRewriteContent) -> String {
        let extractedAt = Date().formatted(.iso8601)
        let opName = payload.op.rawValue
        let reason = payload.reason ?? ""
        return #"{"source_kind":"fact_restructurer","op":"\#(opName)","reason":"\#(escape(reason))","extracted_at":"\#(extractedAt)"}"#
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
