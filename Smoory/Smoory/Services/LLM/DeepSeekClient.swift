import Foundation

/// LLMClient implementation against DeepSeek's OpenAI-compatible chat completions API.
/// See milestone 2.5b in DECISIONS.md for the validation record.
final class DeepSeekClient: LLMClient, @unchecked Sendable {
    private static let endpoint = URL(string: "https://api.deepseek.com/v1/chat/completions")!
    private static let defaultMaxTokens = 4096

    private let session: URLSession
    private let apiKeyProvider: @Sendable () -> String?

    init(
        session: URLSession = .shared,
        apiKeyProvider: @escaping @Sendable () -> String? = {
            KeychainService.read(service: KeychainService.deepseekAPIKeyService)
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

        var encoded: [DeepSeekRequest.Msg] = [
            .init(role: "system", content: systemPrompt, tool_calls: nil, tool_call_id: nil)
        ]
        for m in messages {
            encoded.append(contentsOf: Self.encodeMessage(m))
        }

        let toolDefs: [DeepSeekRequest.ToolDef]? = (tools?.isEmpty ?? true)
            ? nil
            : tools!.map { Self.encodeTool($0) }

        let body = DeepSeekRequest(
            model: Self.modelString(for: model),
            messages: encoded,
            tools: toolDefs,
            max_tokens: Self.defaultMaxTokens
        )

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

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
                let decoded = try JSONDecoder().decode(DeepSeekResponse.self, from: data)
                return try Self.mapResponse(decoded)
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

    // MARK: - Encoding (LLMMessage → DeepSeek messages)

    /// Decomposes a single LLMMessage into one or more DeepSeek messages.
    /// User messages with tool_result content are decomposed into separate role:tool messages,
    /// one per tool result — DeepSeek requires this; Anthropic batches them in a single user msg.
    /// The is_error flag from LLMContent.toolResult is dropped — DeepSeek has no equivalent;
    /// existing tools encode error context inside their content JSON (see TodoToolUtils.errorOutput).
    private static func encodeMessage(_ m: LLMMessage) -> [DeepSeekRequest.Msg] {
        var out: [DeepSeekRequest.Msg] = []

        let textBlocks: [String] = m.content.compactMap {
            if case let .text(t) = $0 { return t }; return nil
        }
        let toolUseBlocks: [(String, String, String)] = m.content.compactMap {
            if case let .toolUse(id, name, args) = $0 { return (id, name, args) }; return nil
        }
        let toolResultBlocks: [(String, String)] = m.content.compactMap {
            if case let .toolResult(id, content, _) = $0 { return (id, content) }; return nil
        }

        switch m.role {
        case .user:
            // Per LLMClient contract, user messages are EITHER plain text OR a batch of
            // tool_results — never both at the same time. Tool results expand to role:tool.
            if !toolResultBlocks.isEmpty {
                for (id, content) in toolResultBlocks {
                    out.append(.init(
                        role: "tool",
                        content: content,
                        tool_calls: nil,
                        tool_call_id: id
                    ))
                }
            } else {
                let combined = textBlocks.joined(separator: "\n\n")
                out.append(.init(
                    role: "user",
                    content: combined,
                    tool_calls: nil,
                    tool_call_id: nil
                ))
            }

        case .assistant:
            // One assistant message carrying both joined text and any tool_calls.
            // Empty-string content when only tool_calls are present (DeepSeek accepts this;
            // see DECISIONS.md milestone 2.5b for the empirical record).
            let textCombined = textBlocks.joined()
            let calls: [DeepSeekRequest.ToolCall]? = toolUseBlocks.isEmpty ? nil :
                toolUseBlocks.map { id, name, args in
                    DeepSeekRequest.ToolCall(
                        id: id,
                        type: "function",
                        function: .init(
                            name: name,
                            arguments: args.trimmingCharacters(in: .whitespaces).isEmpty ? "{}" : args
                        )
                    )
                }
            out.append(.init(
                role: "assistant",
                content: textCombined,
                tool_calls: calls,
                tool_call_id: nil
            ))
        }

        return out
    }

    private static func encodeTool(_ tool: LLMTool) -> DeepSeekRequest.ToolDef {
        DeepSeekRequest.ToolDef(
            type: "function",
            function: .init(
                name: tool.name,
                description: tool.description,
                parameters: tool.inputSchema
            )
        )
    }

    // MARK: - Decoding (DeepSeekResponse → LLMResponse)

    private static func mapResponse(_ resp: DeepSeekResponse) throws -> LLMResponse {
        guard let choice = resp.choices.first else {
            throw LLMClientError.invalidResponse
        }

        var content: [LLMContent] = []
        if let text = choice.message.content, !text.isEmpty {
            content.append(.text(text))
        }
        if let calls = choice.message.tool_calls {
            for call in calls {
                let args = call.function.arguments.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "{}"
                    : call.function.arguments
                content.append(.toolUse(
                    id: call.id,
                    name: call.function.name,
                    parametersJSON: args
                ))
            }
        }

        let stopReason: LLMResponse.StopReason = {
            switch choice.finish_reason {
            case "stop": return .endTurn
            case "tool_calls": return .toolUse
            case "length": return .maxTokens
            default: return .unknown
            }
        }()

        return LLMResponse(
            content: content,
            stopReason: stopReason,
            usage: .init(
                inputTokens: resp.usage.prompt_tokens,
                outputTokens: resp.usage.completion_tokens
            )
        )
    }

    private static func modelString(for tier: ModelTier) -> String {
        switch tier {
        case .fast: "deepseek-chat"
        case .balanced: "deepseek-chat"
        case .heavy: "deepseek-reasoner"
        }
    }

    // MARK: - Wire shapes

    private struct DeepSeekRequest: Encodable {
        let model: String
        let messages: [Msg]
        let tools: [ToolDef]?
        let max_tokens: Int

        struct Msg: Encodable {
            let role: String
            let content: String?
            let tool_calls: [ToolCall]?
            let tool_call_id: String?
        }

        struct ToolCall: Encodable {
            let id: String
            let type: String
            let function: FunctionCall
        }

        struct FunctionCall: Encodable {
            let name: String
            let arguments: String
        }

        struct ToolDef: Encodable {
            let type: String
            let function: FunctionDef
        }

        struct FunctionDef: Encodable {
            let name: String
            let description: String
            let parameters: ToolInputSchema
        }
    }

    private struct DeepSeekResponse: Decodable {
        let choices: [Choice]
        let usage: Usage

        struct Choice: Decodable {
            let index: Int
            let message: Message
            let finish_reason: String
        }

        struct Message: Decodable {
            let role: String
            let content: String?
            let tool_calls: [ToolCall]?
        }

        struct ToolCall: Decodable {
            let id: String
            let type: String
            let function: FunctionCall
        }

        struct FunctionCall: Decodable {
            let name: String
            let arguments: String
        }

        struct Usage: Decodable {
            let prompt_tokens: Int
            let completion_tokens: Int
        }
    }
}
