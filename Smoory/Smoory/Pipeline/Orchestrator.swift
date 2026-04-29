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
        // 2.2b: assemble the full system prompt with always-on compact memory + user_context
        // before the first client.complete. Rebuilt each turn — active summaries can change.
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

            // All tool_result blocks for this round go into a SINGLE user message —
            // Anthropic's API requires this; emitting one user message per tool_result is wrong.
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

            messages.append(LLMMessage(role: .user, content: toolResultBlocks))
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

    /// Build the full system prompt: base prompt + (optional) compact_memory block + user_context block.
    /// Compact memory block is omitted entirely when no active summaries exist (bootstrapping case)
    /// or when the read fails — avoids Claude commenting on placeholder text.
    /// The user_context block is always appended so retrieve_memory stays discoverable.
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
    case toolError(String)                    // Reserved for future use (e.g., aborting on repeated tool failures); not emitted in 2.2a/2.2b.
    case clientError(Error)                   // LLMClient threw
}
