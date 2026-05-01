import Foundation

enum CompleteWeekReviewTool: Tool {
    static let name = "complete_week_review"

    static let description = """
        Call this tool to signal that the week review conversation is naturally complete. \
        Pass a 2-4 sentence summary of what was meaningful from the conversation. The \
        summary is saved as a memory turn for the user to retrieve later. After this \
        tool fires, the week review sheet will close.
        """

    static let confirmationTier: ConfirmationTier = .silent

    static let inputSchema = ToolInputSchema(
        properties: [
            "summary": ToolInputSchemaProperty(
                type: "string",
                description: "A 2-4 sentence summary of what was meaningful from the week review."
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
            content: "[Week review summary] \(input.summary)",
            vector: nil
        )
        try? await context.services.hema.writeTurn(summaryTurn)

        return ToolOutput(
            toolUseId: context.toolUseId,
            content: #"{"status":"complete_week_review_signaled"}"#,
            isError: false
        )
    }

    private static func decodeInput(_ jsonString: String) throws -> Input {
        guard let data = jsonString.data(using: .utf8), !data.isEmpty else {
            throw NSError(
                domain: "CompleteWeekReviewTool",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "empty parameters"]
            )
        }
        return try JSONDecoder().decode(Input.self, from: data)
    }
}
