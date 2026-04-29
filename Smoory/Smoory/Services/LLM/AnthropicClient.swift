import Foundation

final class AnthropicClient: LLMClient, @unchecked Sendable {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let anthropicVersion = "2023-06-01"
    private static let defaultMaxTokens = 1024

    private let session: URLSession
    private let apiKeyProvider: @Sendable () -> String?

    init(
        session: URLSession = .shared,
        apiKeyProvider: @escaping @Sendable () -> String? = {
            KeychainService.read(service: KeychainService.anthropicAPIKeyService)
        }
    ) {
        self.session = session
        self.apiKeyProvider = apiKeyProvider
    }

    func complete(
        model: ModelTier,
        systemPrompt: String,
        messages: [LLMMessage],
        tools: [LLMTool]?
    ) async throws -> LLMResponse {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            throw LLMClientError.missingAPIKey
        }

        // tools intentionally unused in milestone 1.4 — protocol shape preserved for Phase 2.
        _ = tools

        let body = AnthropicRequest(
            model: Self.modelString(for: model),
            max_tokens: Self.defaultMaxTokens,
            system: systemPrompt,
            messages: messages.map { AnthropicRequest.Msg(role: $0.role.rawValue, content: $0.content) }
        )

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw LLMClientError.unknown(error)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw LLMClientError.network(urlError)
        } catch {
            throw LLMClientError.unknown(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMClientError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            do {
                let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
                return Self.mapResponse(decoded)
            } catch {
                throw LLMClientError.decoding(error)
            }
        case 401:
            throw LLMClientError.unauthorized
        case 429:
            throw LLMClientError.rateLimited
        default:
            throw LLMClientError.server(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8)
            )
        }
    }

    private static func modelString(for tier: ModelTier) -> String {
        switch tier {
        case .fast: "claude-haiku-4-5"
        case .balanced: "claude-sonnet-4-6"
        case .heavy: "claude-opus-4-7"
        }
    }

    private static func mapResponse(_ decoded: AnthropicResponse) -> LLMResponse {
        let text = decoded.content
            .compactMap { $0.type == "text" ? $0.text : nil }
            .joined()

        let stopReason: LLMResponse.StopReason = {
            switch decoded.stop_reason {
            case "end_turn": return .endTurn
            case "max_tokens": return .maxTokens
            case "stop_sequence": return .stopSequence
            case "tool_use": return .toolUse
            default: return .unknown
            }
        }()

        return LLMResponse(
            text: text,
            toolCalls: [],   // tool-use mapping deferred to Phase 2
            stopReason: stopReason,
            usage: .init(
                inputTokens: decoded.usage.input_tokens,
                outputTokens: decoded.usage.output_tokens
            )
        )
    }

    // MARK: - Wire shapes

    private struct AnthropicRequest: Encodable {
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [Msg]

        struct Msg: Encodable {
            let role: String
            let content: String
        }
    }

    private struct AnthropicResponse: Decodable {
        let id: String
        let content: [Block]
        let stop_reason: String?
        let usage: Usage

        struct Block: Decodable {
            let type: String
            let text: String?
        }

        struct Usage: Decodable {
            let input_tokens: Int
            let output_tokens: Int
        }
    }
}
