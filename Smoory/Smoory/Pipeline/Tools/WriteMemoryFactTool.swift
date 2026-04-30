import Foundation
import SwiftData

enum WriteMemoryFactTool: Tool {
    static let name = "write_memory_fact"

    static let description = """
        Silently record a fact the user has shared about themselves, their world, or their \
        preferences. Use this when the user states something the assistant should remember \
        for future conversations, like "I'm vegetarian" or "I work at Acme" or "my partner's \
        name is Maria". Only write high-confidence facts (>= 0.85). For lower-confidence \
        observations, do not write — the structuring layer surfaces them as candidates for \
        user confirmation.
        """

    static let confirmationTier: ConfirmationTier = .silent

    static let inputSchema = ToolInputSchema(
        properties: [
            "body": ToolInputSchemaProperty(
                type: "string",
                description: "The fact, stated as a complete sentence in third person."
            ),
            "tags": ToolInputSchemaProperty(
                type: "array",
                description: "Tags categorizing the fact (e.g., ['preferences'], ['work', 'people']).",
                items: ToolInputSchemaItem(type: "string")
            ),
            "confidence": ToolInputSchemaProperty(
                type: "number",
                description: "Confidence in the fact (0.0–1.0). Only write if >= 0.85."
            ),
            "is_private": ToolInputSchemaProperty(
                type: "boolean",
                description: "True if the fact is sensitive and should never be sent to the LLM API in retrieval. Default: false."
            ),
        ],
        required: ["body", "tags", "confidence"]
    )

    private struct Input: Decodable {
        let body: String
        let tags: [String]
        let confidence: Double
        let is_private: Bool?
    }

    static func execute(
        parametersJSON: String,
        context: ToolExecutionContext
    ) async throws -> ToolOutput {
        let input = try Self.decodeInput(parametersJSON)

        guard input.confidence >= 0.85 else {
            return ToolOutput(
                toolUseId: context.toolUseId,
                content: #"{"status":"skipped","reason":"confidence below 0.85 threshold"}"#,
                isError: false
            )
        }

        let extractedAt = Date().formatted(.iso8601)
        let provenance = #"{"source_kind":"chat_assistant_call","extracted_at":"\#(extractedAt)","user_confirmed":false}"#

        let fact = SemanticFact(
            id: UUID(),
            body: input.body,
            tags: input.tags,
            entitiesReferenced: [],
            confidence: input.confidence,
            userConfirmed: false,
            createdAt: Date(),
            expiresAt: nil,
            supersededBy: nil,
            provenanceJSON: provenance,
            vector: nil,
            isPrivate: input.is_private ?? false
        )

        try await context.services.hema.writeFact(fact)

        // Surface silent writes in Feed as auto-applied rows so the user has an audit
        // trail without an interruption (per MEMORY.md "transparency" requirement).
        await Self.recordAutoAppliedCandidate(
            fact: fact,
            modelContainer: context.services.modelContainer,
            chatSessionID: context.chatSessionID
        )

        let json = #"{"status":"written","id":"\#(fact.id.uuidString)"}"#
        return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
    }

    @MainActor
    private static func recordAutoAppliedCandidate(
        fact: SemanticFact,
        modelContainer: ModelContainer,
        chatSessionID: UUID
    ) {
        let row = CandidateWrite()
        row.type = .fact
        row.content = fact.body
        row.confidence = fact.confidence
        row.status = .autoApplied
        row.sourceSessionID = chatSessionID
        row.reviewedAt = Date()
        row.resultEntityID = fact.id
        row.extractingModel = AIProviderStore.current().modelID(for: .balanced)

        let context = ModelContext(modelContainer)
        context.insert(row)
        do {
            try context.save()
        } catch {
            print("[write_memory_fact] failed to record auto-applied candidate: \(error)")
        }
    }

    private static func decodeInput(_ jsonString: String) throws -> Input {
        guard let data = jsonString.data(using: .utf8), !data.isEmpty else {
            throw NSError(
                domain: "WriteMemoryFactTool",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "empty parameters"]
            )
        }
        return try JSONDecoder().decode(Input.self, from: data)
    }
}
