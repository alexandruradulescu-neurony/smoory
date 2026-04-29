import Foundation

enum ChatRole: Int, Codable, Sendable {
    case user = 0
    case assistant = 1
    case system = 2
}

struct ToolCall: Hashable, Sendable {
    let id: String                     // matches Anthropic's tool_use_id
    let toolName: String
    let parametersJSON: String
}

extension ToolCall: Codable {}

struct ToolResult: Hashable, Sendable {
    let toolCallId: String
    let resultJSON: String
    let isError: Bool
}

extension ToolResult: Codable {}
