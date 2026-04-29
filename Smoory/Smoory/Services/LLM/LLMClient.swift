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

enum LLMContent: Sendable, Hashable {
    case text(String)
    case toolUse(id: String, name: String, parametersJSON: String)
    case toolResult(toolUseId: String, content: String, isError: Bool)
}

struct LLMMessage: Sendable, Hashable {
    enum Role: String, Sendable, Hashable {
        case user
        case assistant
    }
    let role: Role
    let content: [LLMContent]

    init(role: Role, content: [LLMContent]) {
        self.role = role
        self.content = content
    }

    /// Convenience initializer for plain-text turns — back-compat with Phase 1 call sites
    /// that pre-date the content-block model.
    init(role: Role, text: String) {
        self.init(role: role, content: [.text(text)])
    }
}

struct LLMTool: Sendable, Hashable {
    let name: String
    let description: String
    let inputSchema: ToolInputSchema
}

struct LLMToolCall: Sendable, Hashable {
    let id: String
    let toolName: String
    let parametersJSON: String
}

struct LLMResponse: Sendable {
    let content: [LLMContent]
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

    /// Concatenation of all `.text(...)` content blocks. Empty string if none.
    var text: String {
        content.compactMap {
            if case let .text(t) = $0 { return t }
            return nil
        }.joined()
    }

    /// Extracts every `.toolUse(...)` content block as an LLMToolCall.
    var toolCalls: [LLMToolCall] {
        content.compactMap {
            if case let .toolUse(id, name, parametersJSON) = $0 {
                return LLMToolCall(id: id, toolName: name, parametersJSON: parametersJSON)
            }
            return nil
        }
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
