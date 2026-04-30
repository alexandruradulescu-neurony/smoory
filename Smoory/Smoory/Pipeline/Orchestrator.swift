import Foundation

@MainActor
final class Orchestrator {
    private let client: LLMClient
    private let registry: [any Tool.Type]
    private let toolDefinitions: [LLMTool]
    private let services: ToolServices
    private let chatSessionID: UUID
    private let maxToolCallRounds: Int

    /// Set by ChatViewModel post-init to break the retain cycle. Awaited for non-silent tools.
    weak var delegate: OrchestratorDelegate?

    init(
        client: LLMClient,
        registry: [any Tool.Type] = ToolRegistry.allTools,
        services: ToolServices,
        chatSessionID: UUID,
        maxToolCallRounds: Int = 5
    ) {
        self.client = client
        self.registry = registry
        self.toolDefinitions = ToolRegistry.anthropicToolDefinitions(for: registry)
        self.services = services
        self.chatSessionID = chatSessionID
        self.maxToolCallRounds = maxToolCallRounds
    }

    func send(
        systemPrompt: String,
        history: [LLMMessage],
        userMessage: String,
        modelTier: ModelTier,
        assistantTurnID: UUID
    ) async throws -> OrchestratorTurn {
        let fullSystemPrompt = await Self.assemblePrompt(
            basePrompt: systemPrompt,
            hema: services.hema
        )

        var messages = history + [LLMMessage(role: .user, text: userMessage)]
        var toolExchanges: [ToolExchange] = []
        var rounds = 0

        while true {
            let response: LLMResponse
            do {
                response = try await client.complete(
                    model: modelTier,
                    systemPrompt: fullSystemPrompt,
                    messages: messages,
                    tools: toolDefinitions
                )
            } catch {
                return OrchestratorTurn(
                    finalText: "",
                    toolExchanges: toolExchanges,
                    stoppedReason: .clientError(error),
                    totalRounds: rounds
                )
            }

            messages.append(LLMMessage(role: .assistant, content: response.content))

            let toolUses: [(id: String, name: String, input: String)] = response.content.compactMap { block in
                if case let .toolUse(id, name, parametersJSON) = block {
                    return (id, name, parametersJSON)
                }
                return nil
            }

            if toolUses.isEmpty {
                return OrchestratorTurn(
                    finalText: response.text,
                    toolExchanges: toolExchanges,
                    stoppedReason: .naturalEnd,
                    totalRounds: rounds
                )
            }

            rounds += 1

            if rounds > maxToolCallRounds {
                let priorText = response.text
                let suffix = "(Hit tool-call budget; couldn't complete the chain.)"
                let finalText = priorText.isEmpty ? suffix : "\(priorText)\n\n\(suffix)"
                return OrchestratorTurn(
                    finalText: finalText,
                    toolExchanges: toolExchanges,
                    stoppedReason: .maxRoundsReached,
                    totalRounds: rounds
                )
            }

            // Single batched user message with all tool_result blocks (Anthropic requires this).
            var toolResultBlocks: [LLMContent] = []
            var anyCancelled = false
            for use in toolUses {
                let exchange = await executeToolUse(
                    id: use.id,
                    name: use.name,
                    parametersJSON: use.input,
                    assistantTurnID: assistantTurnID
                )
                toolExchanges.append(exchange)
                toolResultBlocks.append(.toolResult(
                    toolUseId: exchange.result.toolUseId,
                    content: exchange.result.content,
                    isError: exchange.result.isError
                ))
                // If Task was cancelled while awaiting confirmation, the delegate returns
                // a {"status":"cancelled"} marker — surface as .userCancelled stop reason.
                if exchange.result.content.contains("\"cancelled\"") && exchange.result.isError {
                    anyCancelled = true
                }
            }

            if anyCancelled {
                return OrchestratorTurn(
                    finalText: response.text,
                    toolExchanges: toolExchanges,
                    stoppedReason: .userCancelled,
                    totalRounds: rounds
                )
            }

            messages.append(LLMMessage(role: .user, content: toolResultBlocks))
        }
    }

    private func executeToolUse(
        id: String,
        name: String,
        parametersJSON: String,
        assistantTurnID: UUID
    ) async -> ToolExchange {
        guard let toolType = registry.first(where: { $0.name == name }) else {
            return ToolExchange(
                toolName: name,
                parametersJSON: parametersJSON,
                result: ToolOutput(toolUseId: id, content: "Unknown tool: \(name)", isError: true)
            )
        }

        // Silent tools execute directly.
        if toolType.confirmationTier == .silent {
            let context = ToolExecutionContext(
                toolUseId: id,
                chatSessionID: chatSessionID,
                services: services
            )
            do {
                let output = try await toolType.execute(parametersJSON: parametersJSON, context: context)
                return ToolExchange(toolName: name, parametersJSON: parametersJSON, result: output)
            } catch {
                return ToolExchange(
                    toolName: name,
                    parametersJSON: parametersJSON,
                    result: ToolOutput(
                        toolUseId: id,
                        content: "Tool error: \(error.localizedDescription)",
                        isError: true
                    )
                )
            }
        }

        // Non-silent: route to delegate (ChatViewModel) for confirmation.
        guard let delegate else {
            return ToolExchange(
                toolName: name,
                parametersJSON: parametersJSON,
                result: ToolOutput(
                    toolUseId: id,
                    content: "Tool requires confirmation; no delegate available.",
                    isError: true
                )
            )
        }

        let output = await delegate.handlePendingAction(
            toolName: name,
            parametersJSON: parametersJSON,
            toolUseId: id,
            confirmationTier: toolType.confirmationTier,
            assistantTurnID: assistantTurnID
        )
        return ToolExchange(toolName: name, parametersJSON: parametersJSON, result: output)
    }

    private static func assemblePrompt(basePrompt: String, hema: HemaService) async -> String {
        let memories: [CompactMemory]
        do {
            memories = try await hema.readActiveCompactMemories()
        } catch {
            print("[orchestrator] readActiveCompactMemories failed — proceeding without compact memory: \(error)")
            memories = []
        }

        let overall = body(of: memories, kind: .overall)
        let recent = body(of: memories, kind: .recent)
        let today = body(of: memories, kind: .today)

        let allEmpty = (overall == nil && recent == nil && today == nil)

        var sections: [String] = [basePrompt]

        if !allEmpty {
            sections.append("""
            <compact_memory>
            Overall: \(overall ?? "(not yet generated)")
            Recent: \(recent ?? "(not yet generated)")
            Today: \(today ?? "(not yet generated)")
            </compact_memory>
            """)
        }

        let todayString = Date().formatted(.dateTime.weekday(.wide).year().month(.wide).day())
        sections.append("""
        <current_date>
        Today is \(todayString). Resolve relative dates ("today", "tomorrow", "next Monday") against this.
        </current_date>
        """)

        sections.append("""
        <user_context>
        You have access to the user's accumulated memory through the retrieve_memory tool when \
        relevant. The compact summaries above are always-on context. For specific facts, names, \
        past events, or relationships, use retrieve_memory with a focused query.
        </user_context>
        """)

        return sections.joined(separator: "\n\n")
    }

    private static func body(of memories: [CompactMemory], kind: CompactMemory.Kind) -> String? {
        memories.first(where: { $0.kind == kind })?.body
    }
}

struct OrchestratorTurn: Sendable {
    let finalText: String
    let toolExchanges: [ToolExchange]
    let stoppedReason: OrchestratorStopReason
    let totalRounds: Int
}

struct ToolExchange: Sendable {
    let toolName: String
    let parametersJSON: String
    let result: ToolOutput
}

enum OrchestratorStopReason: Sendable {
    case naturalEnd
    case maxRoundsReached
    case toolError(String)                    // Reserved for future use.
    case clientError(Error)
    case userCancelled                        // user navigated away mid-confirmation
}
