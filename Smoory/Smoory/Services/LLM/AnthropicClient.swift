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

        let encodedMessages: [AnthropicRequest.Msg]
        do {
            encodedMessages = try messages.map { try Self.encodeMessage($0) }
        } catch {
            throw LLMClientError.unknown(error)
        }

        let toolDefs: [AnthropicRequest.ToolDef]? = (tools?.isEmpty ?? true)
            ? nil
            : tools!.map { Self.encodeTool($0) }

        let body = AnthropicRequest(
            model: Self.modelString(for: model),
            max_tokens: Self.defaultMaxTokens,
            system: systemPrompt,
            messages: encodedMessages,
            tools: toolDefs
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

    // MARK: - Encoding (LLMMessage → Anthropic content blocks)

    private static func encodeMessage(_ message: LLMMessage) throws -> AnthropicRequest.Msg {
        let blocks: [AnthropicRequest.ContentBlock] = try message.content.map { content in
            switch content {
            case .text(let text):
                return .text(.init(text: text))
            case .toolUse(let id, let name, let parametersJSON):
                let inputJSON = try Self.parseJSONValue(parametersJSON)
                return .toolUse(.init(id: id, name: name, input: inputJSON))
            case .toolResult(let toolUseId, let content, let isError):
                return .toolResult(.init(
                    tool_use_id: toolUseId,
                    content: content,
                    is_error: isError
                ))
            }
        }
        return AnthropicRequest.Msg(role: message.role.rawValue, content: blocks)
    }

    private static func encodeTool(_ tool: LLMTool) -> AnthropicRequest.ToolDef {
        AnthropicRequest.ToolDef(
            name: tool.name,
            description: tool.description,
            input_schema: tool.inputSchema
        )
    }

    /// Parse a parametersJSON String into a JSONValue tree. Empty / blank input becomes
    /// an empty object so `tool_use.input: {}` is sent correctly.
    private static func parseJSONValue(_ string: String) throws -> JSONValue {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return .object([:])
        }
        guard let data = trimmed.data(using: .utf8) else {
            return .object([:])
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func encodeJSONValue(_ value: JSONValue) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - Decoding (Anthropic response → LLMResponse)

    private static func mapResponse(_ decoded: AnthropicResponse) throws -> LLMResponse {
        var content: [LLMContent] = []
        for block in decoded.content {
            switch block.type {
            case "text":
                content.append(.text(block.text ?? ""))
            case "tool_use":
                guard let id = block.id, let name = block.name else { continue }
                let paramsJSON: String
                if let input = block.input {
                    paramsJSON = (try? Self.encodeJSONValue(input)) ?? "{}"
                } else {
                    paramsJSON = "{}"
                }
                content.append(.toolUse(id: id, name: name, parametersJSON: paramsJSON))
            default:
                continue
            }
        }

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
            content: content,
            stopReason: stopReason,
            usage: .init(
                inputTokens: decoded.usage.input_tokens,
                outputTokens: decoded.usage.output_tokens
            )
        )
    }

    private static func modelString(for tier: ModelTier) -> String {
        switch tier {
        case .fast: "claude-haiku-4-5"
        case .balanced: "claude-sonnet-4-6"
        case .heavy: "claude-opus-4-7"
        }
    }

    // MARK: - Wire shapes

    private struct AnthropicRequest: Encodable {
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [Msg]
        let tools: [ToolDef]?

        struct Msg: Encodable {
            let role: String
            let content: [ContentBlock]
        }

        struct ToolDef: Encodable {
            let name: String
            let description: String
            let input_schema: ToolInputSchema
        }

        enum ContentBlock: Encodable {
            case text(TextBlock)
            case toolUse(ToolUseBlock)
            case toolResult(ToolResultBlock)

            func encode(to encoder: Encoder) throws {
                switch self {
                case .text(let block): try block.encode(to: encoder)
                case .toolUse(let block): try block.encode(to: encoder)
                case .toolResult(let block): try block.encode(to: encoder)
                }
            }
        }

        struct TextBlock: Encodable {
            let type: String = "text"
            let text: String
        }

        struct ToolUseBlock: Encodable {
            let type: String = "tool_use"
            let id: String
            let name: String
            let input: JSONValue
        }

        struct ToolResultBlock: Encodable {
            let type: String = "tool_result"
            let tool_use_id: String
            let content: String
            let is_error: Bool
        }
    }

    private struct AnthropicResponse: Decodable {
        let id: String
        let content: [Block]
        let stop_reason: String?
        let usage: Usage

        struct Block: Decodable {
            let type: String
            let text: String?      // when type == "text"
            let id: String?        // when type == "tool_use"
            let name: String?      // when type == "tool_use"
            let input: JSONValue?  // when type == "tool_use"
        }

        struct Usage: Decodable {
            let input_tokens: Int
            let output_tokens: Int
        }
    }

    // MARK: - JSONValue (private — round-trips arbitrary JSON in tool_use.input)

    indirect enum JSONValue: Sendable, Hashable, Codable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() {
                self = .null
            } else if let b = try? c.decode(Bool.self) {
                self = .bool(b)
            } else if let i = try? c.decode(Int.self) {
                self = .int(i)
            } else if let d = try? c.decode(Double.self) {
                self = .double(d)
            } else if let s = try? c.decode(String.self) {
                self = .string(s)
            } else if let arr = try? c.decode([JSONValue].self) {
                self = .array(arr)
            } else if let obj = try? c.decode([String: JSONValue].self) {
                self = .object(obj)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: c,
                    debugDescription: "Cannot decode JSONValue"
                )
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null: try c.encodeNil()
            case .bool(let b): try c.encode(b)
            case .int(let i): try c.encode(i)
            case .double(let d): try c.encode(d)
            case .string(let s): try c.encode(s)
            case .array(let a): try c.encode(a)
            case .object(let o): try c.encode(o)
            }
        }
    }
}
