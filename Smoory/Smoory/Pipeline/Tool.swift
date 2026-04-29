import Foundation

/// A capability the LLM can invoke. Static-only protocol — tools are stateless types.
/// Conforming types are usually empty enums (`enum GetCalendarWindowTool: Tool {}`)
/// rather than instances.
protocol Tool: Sendable {
    static var name: String { get }
    static var description: String { get }
    static var inputSchema: ToolInputSchema { get }
    static var confirmationTier: ConfirmationTier { get }

    static func execute(
        parametersJSON: String,
        context: ToolExecutionContext
    ) async throws -> ToolOutput
}

/// JSON Schema subset that Anthropic's tool definition accepts.
/// Encoded directly as the `input_schema` field in the request.
struct ToolInputSchema: Codable, Sendable, Hashable {
    let type: String                                        // always "object"
    let properties: [String: ToolInputSchemaProperty]
    let required: [String]

    init(
        type: String = "object",
        properties: [String: ToolInputSchemaProperty],
        required: [String]
    ) {
        self.type = type
        self.properties = properties
        self.required = required
    }
}

struct ToolInputSchemaProperty: Codable, Sendable, Hashable {
    let type: String           // "string" | "integer" | "boolean" | "array" | etc.
    let description: String?
    let items: ToolInputSchemaItem?

    init(type: String, description: String?, items: ToolInputSchemaItem? = nil) {
        self.type = type
        self.description = description
        self.items = items
    }
}

struct ToolInputSchemaItem: Codable, Sendable, Hashable {
    let type: String           // element type for arrays
}

/// What a tool produces at runtime. Distinct from `ToolResult` in `Models/Types/ChatTypes.swift`,
/// which is the placeholder type for ChatMessage persistence (Phase 1).
struct ToolOutput: Sendable, Hashable, Codable {
    let toolUseId: String
    let content: String        // JSON or plain text fed back to Claude as tool_result content
    let isError: Bool
}
