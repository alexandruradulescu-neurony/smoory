import Foundation

enum RetrieveMemoryTool: Tool {
    static let name = "retrieve_memory"

    static let description = """
        Retrieve relevant facts the assistant has learned about the user over time. Use this \
        when the user asks about something that likely came up in a past conversation, or when \
        the current topic benefits from earlier context (e.g., who someone is, when an event \
        happened, the user's preferences). Returns ranked facts with similarity scores.
        """

    static let inputSchema = ToolInputSchema(
        properties: [
            "query": ToolInputSchemaProperty(
                type: "string",
                description: "The retrieval query — what facts to look for."
            ),
            "tags": ToolInputSchemaProperty(
                type: "array",
                description: "Optional tag filter. Returns facts matching any of these tags.",
                items: ToolInputSchemaItem(type: "string")
            ),
            "k": ToolInputSchemaProperty(
                type: "integer",
                description: "Max results (default 5, max 20)."
            ),
        ],
        required: ["query"]
    )

    static let confirmationTier: ConfirmationTier = .silent

    private struct Input: Decodable {
        let query: String
        let tags: [String]?
        let k: Int?
    }

    private struct FactPayload: Encodable {
        let body: String
        let tags: [String]
        let similarity: Double
        let isUserConfirmed: Bool
        let ageInDays: Int
    }

    static func execute(
        parametersJSON: String,
        context: ToolExecutionContext
    ) async throws -> ToolOutput {
        let input = try Self.decodeInput(parametersJSON)
        let k = max(1, min(input.k ?? 5, 20))

        let results = try await context.services.hema.retrieveSimilarFacts(
            query: input.query,
            k: k,
            tagFilter: input.tags,
            entityFilter: nil,
            excludeExpired: true,
            excludePrivate: true            // ALWAYS true through this path; non-overridable
        )

        let now = Date()
        let payload = results.map { (fact, similarity) -> FactPayload in
            let days = Calendar.current.dateComponents(
                [.day], from: fact.createdAt, to: now
            ).day ?? 0
            return FactPayload(
                body: fact.body,
                tags: fact.tags,
                similarity: (similarity * 1000).rounded() / 1000,
                isUserConfirmed: fact.userConfirmed,
                ageInDays: max(0, days)
            )
        }

        let json = try Self.encodeJSON(payload)
        return ToolOutput(toolUseId: context.toolUseId, content: json, isError: false)
    }

    private static func decodeInput(_ jsonString: String) throws -> Input {
        guard let data = jsonString.data(using: .utf8), !data.isEmpty else {
            throw NSError(
                domain: "RetrieveMemoryTool",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "empty parameters"]
            )
        }
        return try JSONDecoder().decode(Input.self, from: data)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}
