import Foundation

/// Builds a fresh LLMClient for the currently selected provider. Called per-call by
/// RoutingLLMClient so provider switching takes effect immediately, no app restart.
enum LLMClientFactory {
    static func makeCurrent() -> LLMClient {
        switch AIProviderStore.current() {
        case .anthropic: return AnthropicClient()
        case .deepseek: return DeepSeekClient()
        }
    }
}
