import Foundation

enum ToolRegistry {
    static let allTools: [any Tool.Type] = [
        GetCalendarWindowTool.self,
        GetActiveGoalsTool.self,
        GetOpenTodosTool.self,
    ]

    static func tool(named name: String) -> (any Tool.Type)? {
        allTools.first { $0.name == name }
    }

    /// Render the registry as the LLMTool array Anthropic's `tools` field expects.
    /// Defaults to `allTools`; the parameter exists for future per-call subset filtering
    /// per TOOLS.md ("only include the subset relevant to the current loop type").
    static func anthropicToolDefinitions(for tools: [any Tool.Type] = allTools) -> [LLMTool] {
        tools.map { tool in
            LLMTool(
                name: tool.name,
                description: tool.description,
                inputSchema: tool.inputSchema
            )
        }
    }
}
