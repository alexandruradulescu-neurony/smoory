import Foundation
import SwiftData

/// Runs the structuring-layer fast-tier LLM call after each chat turn and persists candidates.
/// Provider is whatever AIProviderStore points to (Anthropic Haiku or DeepSeek chat).
/// Best-effort: any failure is logged and silently swallowed; never disrupts chat.
@MainActor
final class StructuringService {
    private let client: LLMClient
    private let modelContainer: ModelContainer

    private static let confidenceFloor: Double = 0.5

    init(client: LLMClient, modelContainer: ModelContainer) {
        self.client = client
        self.modelContainer = modelContainer
    }

    func extract(
        userMessage: String,
        recentTurns: [String],
        chatSessionID: UUID,
        sourceTurnID: UUID?,
        alreadyHandled: StructuringPrompt.AlreadyHandled
    ) async {
        let trimmed = userMessage.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let snapshot = await snapshotExistingEntities()
        let userPrompt = StructuringPrompt.assembleUserMessage(
            userMessage: trimmed,
            recentTurns: recentTurns,
            snapshot: snapshot,
            alreadyHandled: alreadyHandled
        )

        let response: LLMResponse
        do {
            response = try await client.complete(
                model: .fast,
                systemPrompt: StructuringPrompt.systemPrompt,
                messages: [LLMMessage(role: .user, text: userPrompt)],
                tools: []
            )
        } catch {
            print("[structuring] fast-tier call failed: \(error)")
            return
        }

        guard let parsed = StructuringPrompt.parse(response.text) else {
            StructuringFailureCounter.shared.increment()
            print("[structuring] could not parse response as JSON. Raw first 200: \(response.text.prefix(200))")
            return
        }

        // Defensive filter — the structuring LLM is told via the prompt to skip
        // already-handled items, but it sometimes re-emits them anyway. Drop matches
        // client-side so chat-created todos/facts can't reappear in the Feed.
        let handledTodos = Set(alreadyHandled.createdTodoTitles.map(Self.normalize))
        let handledFacts = Set(alreadyHandled.writtenFactBodies.map(Self.normalize))

        let kept = parsed.filter { p in
            guard p.confidence >= Self.confidenceFloor else { return false }
            let normContent = Self.normalize(p.content)
            let normPhrase = Self.normalize(p.userPhrase)
            switch p.type {
            case .todo:
                return !handledTodos.contains(normContent)
                    && !handledTodos.contains(normPhrase)
            case .fact:
                return !handledFacts.contains(normContent)
                    && !handledFacts.contains(normPhrase)
            default:
                return true
            }
        }
        if kept.isEmpty {
            return
        }

        let extractingModel = AIProviderStore.current().modelID(for: .fast)

        await persistCandidates(
            kept,
            chatSessionID: chatSessionID,
            sourceTurnID: sourceTurnID,
            extractingModel: extractingModel
        )
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func snapshotExistingEntities() async -> StructuringPrompt.Snapshot {
        let context = ModelContext(modelContainer)

        let roles = (try? context.fetch(FetchDescriptor<Role>())) ?? []
        let goals = (try? context.fetch(FetchDescriptor<Goal>())) ?? []
        let projects = (try? context.fetch(FetchDescriptor<Project>())) ?? []
        let persons = (try? context.fetch(FetchDescriptor<Person>())) ?? []

        return StructuringPrompt.Snapshot(
            roleNames: roles.map(\.name).filter { !$0.isEmpty },
            goalTitles: goals.map(\.title).filter { !$0.isEmpty },
            projectTitles: projects.map(\.title).filter { !$0.isEmpty },
            personNames: persons.map(\.displayName).filter { !$0.isEmpty }
        )
    }

    private func persistCandidates(
        _ parsed: [ParsedCandidate],
        chatSessionID: UUID,
        sourceTurnID: UUID?,
        extractingModel: String
    ) async {
        let context = ModelContext(modelContainer)
        for p in parsed {
            let row = CandidateWrite()
            row.type = p.type
            row.content = p.content
            row.confidence = p.confidence
            row.userPhrase = p.userPhrase
            row.expiresAt = p.expiresAt
            row.sourceSessionID = chatSessionID
            row.sourceTurnID = sourceTurnID
            row.extractingModel = extractingModel
            row.status = .pending
            context.insert(row)
        }
        do {
            try context.save()
            print("[structuring] persisted \(parsed.count) candidate(s)")
        } catch {
            print("[structuring] save failed: \(error)")
        }
    }
}
