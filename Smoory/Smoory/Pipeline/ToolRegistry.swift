import Foundation

enum ToolRegistry {
    static let allTools: [any Tool.Type] = [
        GetCalendarWindowTool.self,
        GetActiveGoalsTool.self,
        GetOpenTodosTool.self,
        RetrieveMemoryTool.self,
        CreateTodoTool.self,
        CompleteTodoTool.self,
        UpdateTodoTool.self,
        DeferTodoTool.self,
        DeleteTodoTool.self,
        CreateSubtaskTool.self,
        WriteMemoryFactTool.self,
        CompleteDayReviewTool.self,
        PostponeScheduledActionTool.self,
        SkipScheduledActionTool.self,
    ]

    static func tool(named name: String) -> (any Tool.Type)? {
        allTools.first { $0.name == name }
    }

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
