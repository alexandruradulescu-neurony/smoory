import Foundation

protocol LLMClient: Sendable {
    func complete(
        model: ModelTier,
        systemPrompt: String,
        messages: [LLMMessage],
        tools: [LLMTool]?
    ) async throws -> LLMResponse
}

enum ModelTier: Sendable {
    case fast
    case balanced
    case heavy
}

struct LLMMessage: Sendable, Hashable {
    enum Role: String, Sendable, Hashable {
        case user
        case assistant
    }
    let role: Role
    let content: String
}

struct LLMTool: Sendable, Hashable {
    let name: String
    let description: String
    let inputSchemaJSON: String
}

struct LLMToolCall: Sendable, Hashable {
    let id: String
    let toolName: String
    let parametersJSON: String
}

struct LLMResponse: Sendable {
    let text: String
    let toolCalls: [LLMToolCall]
    let stopReason: StopReason
    let usage: TokenUsage

    enum StopReason: String, Sendable {
        case endTurn
        case maxTokens
        case stopSequence
        case toolUse
        case unknown
    }

    struct TokenUsage: Sendable, Hashable {
        let inputTokens: Int
        let outputTokens: Int
    }
}

enum LLMClientError: Error {
    case missingAPIKey
    case network(URLError)
    case invalidResponse
    case unauthorized
    case rateLimited
    case server(status: Int, body: String?)
    case decoding(Error)
    case unknown(Error)
}
