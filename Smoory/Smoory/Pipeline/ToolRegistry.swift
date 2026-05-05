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
        CreateScheduledActionTool.self,
        GetMyScheduledActionsTool.self,
        CompleteWeekReviewTool.self,
        GetListsTool.self,
        GetListItemsTool.self,
        CreateListTool.self,
        AddToListTool.self,
        CompleteListItemTool.self,
        RemoveFromListTool.self,
        DeleteListTool.self,
        RenameListTool.self,
        ReorderListItemsTool.self,
        UpdateListItemTool.self,
        GetOffPeriodsTool.self,
        CompleteEndOfDayTool.self,
    ]

    static func tool(named name: String) -> (any Tool.Type)? {
        allTools.first { $0.name == name }
    }

    /// Subset used by background-generation flows (morning brief, week-review pattern
    /// analysis, etc.) where the LLM should be able to *read* the user's state but
    /// must never mutate it. Bug-fix follow-up to the report finding that
    /// `MorningBriefGenerator` passed `allTools` and a hallucinated silent-write call
    /// could leak state changes through.
    static func readOnlyToolsForReviews() -> [any Tool.Type] {
        [
            GetCalendarWindowTool.self,
            GetActiveGoalsTool.self,
            GetOpenTodosTool.self,
            RetrieveMemoryTool.self,
            GetListsTool.self,
            GetListItemsTool.self,
            GetOffPeriodsTool.self,
            GetMyScheduledActionsTool.self
        ]
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
