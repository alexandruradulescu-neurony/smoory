import Foundation

/// Thin LLMClient that delegates to whichever provider is currently selected. ChatViewModel
/// and StructuringService hold this once at init; the actual provider is resolved per call,
/// so toggling in Settings takes effect on the next request.
final class RoutingLLMClient: LLMClient, @unchecked Sendable {
    func complete(
        model: ModelTier,
        systemPrompt: String,
        messages: [LLMMessage],
        tools: [LLMTool]?
    ) async throws -> LLMResponse {
        let inner = LLMClientFactory.makeCurrent()
        return try await inner.complete(
            model: model,
            systemPrompt: systemPrompt,
            messages: messages,
            tools: tools
        )
    }
}
