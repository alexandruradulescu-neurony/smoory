import Foundation

@MainActor
final class Orchestrator {
    private let client: LLMClient
    private let registry: [any Tool.Type]
    private let toolDefinitions: [LLMTool]
    private let services: ToolServices
    private let chatSessionID: UUID
    private let maxToolCallRounds: Int

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
        modelTier: ModelTier
    ) async throws -> OrchestratorTurn {
        var messages = history + [LLMMessage(role: .user, text: userMessage)]
        var toolExchanges: [ToolExchange] = []
        var rounds = 0

        while true {
            // 1. Call Claude
            let response: LLMResponse
            do {
                response = try await client.complete(
                    model: modelTier,
                    systemPrompt: systemPrompt,
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

            // 2. Always append the assistant response (text + tool_use blocks) to history
            messages.append(LLMMessage(role: .assistant, content: response.content))

            // 3. Extract tool_use blocks
            let toolUses: [(id: String, name: String, input: String)] = response.content.compactMap { block in
                if case let .toolUse(id, name, parametersJSON) = block {
                    return (id, name, parametersJSON)
                }
                return nil
            }

            // 4. No tool calls → natural end
            if toolUses.isEmpty {
                return OrchestratorTurn(
                    finalText: response.text,
                    toolExchanges: toolExchanges,
                    stoppedReason: .naturalEnd,
                    totalRounds: rounds
                )
            }

            // 5. Tool calls present — count this round
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

            // 6. Execute each tool call, collect tool_result blocks
            //    All tool_result blocks for this round go into a SINGLE user message —
            //    Anthropic's API requires this; emitting one user message per tool_result is wrong.
            var toolResultBlocks: [LLMContent] = []
            for use in toolUses {
                let exchange = await executeToolUse(
                    id: use.id,
                    name: use.name,
                    parametersJSON: use.input
                )
                toolExchanges.append(exchange)
                toolResultBlocks.append(.toolResult(
                    toolUseId: exchange.result.toolUseId,
                    content: exchange.result.content,
                    isError: exchange.result.isError
                ))
            }

            // Single batched user message with all tool_result blocks
            messages.append(LLMMessage(role: .user, content: toolResultBlocks))
            // Loop back
        }
    }

    private func executeToolUse(
        id: String,
        name: String,
        parametersJSON: String
    ) async -> ToolExchange {
        guard let toolType = registry.first(where: { $0.name == name }) else {
            return ToolExchange(
                toolName: name,
                parametersJSON: parametersJSON,
                result: ToolOutput(toolUseId: id, content: "Unknown tool: \(name)", isError: true)
            )
        }

        // 2.2a only handles .silent — non-silent tools error out until 2.2c lands the confirmation UI.
        guard toolType.confirmationTier == .silent else {
            return ToolExchange(
                toolName: name,
                parametersJSON: parametersJSON,
                result: ToolOutput(
                    toolUseId: id,
                    content: "Tool requires confirmation; UI not yet implemented in this build.",
                    isError: true
                )
            )
        }

        let context = ToolExecutionContext(
            toolUseId: id,
            chatSessionID: chatSessionID,
            services: services
        )

        do {
            let output = try await toolType.execute(parametersJSON: parametersJSON, context: context)
            return ToolExchange(
                toolName: name,
                parametersJSON: parametersJSON,
                result: output
            )
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
}

struct OrchestratorTurn: Sendable {
    let finalText: String                     // what the user sees
    let toolExchanges: [ToolExchange]         // chronological list across all rounds
    let stoppedReason: OrchestratorStopReason
    let totalRounds: Int
}

struct ToolExchange: Sendable {
    let toolName: String
    let parametersJSON: String
    let result: ToolOutput
}

enum OrchestratorStopReason: Sendable {
    case naturalEnd                           // Claude finished without more tool calls
    case maxRoundsReached                     // hit maxToolCallRounds cap
    case toolError(String)                    // Reserved for future use (e.g., aborting on repeated tool failures); not emitted in 2.2a.
    case clientError(Error)                   // LLMClient threw
}
