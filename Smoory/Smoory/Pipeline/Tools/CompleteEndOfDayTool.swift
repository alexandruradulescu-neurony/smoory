import Foundation

/// 4.10 — closes the end-of-day session, persists a 1–2 sentence operational summary
/// as a memory turn so it shows up in retrieval the next morning, and triggers the
/// scheduled-action completion flow. Mirrors `CompleteDayReviewTool` but skips the
/// batched fact extraction + restructurer piggybacks — end-of-day summaries are
/// short and operational; reflection-style content lives on day-review session.
enum CompleteEndOfDayTool: Tool {
    static let name = "complete_end_of_day"

    static let description = """
        Call this tool to signal that the end-of-day shutdown conversation is complete. \
        Pass a 1–2 sentence summary of what's tied up and what's lined up for tomorrow. \
        The summary is saved as a memory turn so the user can retrieve it the next \
        morning. After this tool fires, the end-of-day sheet will close.
        """

    static let confirmationTier: ConfirmationTier = .silent

    static let inputSchema = ToolInputSchema(
        properties: [
            "summary": ToolInputSchemaProperty(
                type: "string",
                description: "1–2 sentences capturing what's wrapped + tomorrow's first focus."
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
            content: "[End-of-day summary] \(input.summary)",
            vector: nil
        )
        try? await context.services.hema.writeTurn(summaryTurn)

        return ToolOutput(
            toolUseId: context.toolUseId,
            content: #"{"status":"complete_end_of_day_signaled"}"#,
            isError: false
        )
    }

    private static func decodeInput(_ jsonString: String) throws -> Input {
        guard let data = jsonString.data(using: .utf8), !data.isEmpty else {
            throw NSError(
                domain: "CompleteEndOfDayTool",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "empty parameters"]
            )
        }
        return try JSONDecoder().decode(Input.self, from: data)
    }
}
