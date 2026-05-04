import Foundation

enum CompleteDayReviewTool: Tool {
    static let name = "complete_day_review"

    static let description = """
        Call this tool to signal that the day review conversation is naturally complete. \
        Pass a brief one-paragraph summary of what was meaningful from the conversation. \
        The summary is saved as a memory turn for the user to retrieve later. After this \
        tool fires, the day review sheet will close.
        """

    static let confirmationTier: ConfirmationTier = .silent

    static let inputSchema = ToolInputSchema(
        properties: [
            "summary": ToolInputSchemaProperty(
                type: "string",
                description: "A 2-4 sentence summary of what was meaningful from the day review."
            )
        ],
        required: ["summary"]
    )

    private struct Input: Decodable { let summary: String }

    static func execute(parametersJSON: String, context: ToolExecutionContext) async throws -> ToolOutput {
        let input = try decodeInput(parametersJSON)

        let summaryTurn = MemoryTurn(
            id: UUID(),
            createdAt: Date(),
            chatSessionID: context.chatSessionID,
            role: .assistant,
            content: "[Day review summary] \(input.summary)",
            vector: nil
        )
        try? await context.services.hema.writeTurn(summaryTurn)

        // 4.4 — batched fact extraction piggyback. Run AFTER the summary turn
        // is persisted so today's reflection becomes part of the extraction
        // window. Salience-gated; if the day's turns don't contain anything
        // memory-worthy, the extractor skips silently.
        if let extractor = context.services.batchedFactExtractor {
            await Self.runDayReviewExtraction(extractor: extractor, hema: context.services.hema)
        }

        // 4.5 — fact restructurer pass. Runs AFTER the batched extractor so
        // its input includes any facts freshly extracted during this same
        // day-review (e.g., a fact "Maria works at City Hospital" written
        // moments ago can be a target for a refine/merge proposal).
        // Conservative LLM prompt + 5 ops/day cap protect Feed from spam.
        if let restructurer = context.services.factRestructurer {
            await restructurer.restructure()
        }

        return ToolOutput(
            toolUseId: context.toolUseId,
            content: #"{"status":"complete_day_review_signaled"}"#,
            isError: false
        )
    }

    /// Pulls today's memory_turns from hema (all chat sessions, not just the
    /// review's own session — the user's main-chat turns from earlier today
    /// are valuable extraction input alongside the review reflection) and
    /// hands them to the batched extractor.
    private static func runDayReviewExtraction(
        extractor: BatchedFactExtractor,
        hema: HemaService
    ) async {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        let turns = (try? await hema.readAllTurns(limit: 500, since: startOfToday)) ?? []
        // readAllTurns returns DESC; extractor wants chronological for
        // arc-sensitive prose generation.
        let chronological = Array(turns.reversed())
        await extractor.extract(turns: chronological, trigger: .dayReviewPiggyback)
    }

    private static func decodeInput(_ jsonString: String) throws -> Input {
        guard let data = jsonString.data(using: .utf8), !data.isEmpty else {
            throw NSError(
                domain: "CompleteDayReviewTool",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "empty parameters"]
            )
        }
        return try JSONDecoder().decode(Input.self, from: data)
    }
}
