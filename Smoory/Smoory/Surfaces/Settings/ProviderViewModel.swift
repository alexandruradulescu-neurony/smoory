import Foundation
import Observation

@Observable
@MainActor
final class ProviderViewModel {
    var selected: AIProvider {
        didSet { AIProviderStore.set(selected) }
    }
    private(set) var isTestingConnection: Bool = false
    private(set) var lastTestResult: TestResult?

    struct TestResult: Sendable {
        let success: Bool
        let message: String
    }

    init() {
        self.selected = AIProviderStore.current()
    }

    /// Issues a minimal LLM call against the currently selected provider to verify the
    /// API key + network. The selected provider may differ from what was active when the
    /// view was built — RoutingLLMClient resolves at call time.
    func testConnection() async {
        isTestingConnection = true
        defer { isTestingConnection = false }

        let client: LLMClient = LLMClientFactory.makeCurrent()
        do {
            let response = try await client.complete(
                model: .fast,
                systemPrompt: "You are a test responder.",
                messages: [LLMMessage(role: .user, text: "Reply with exactly the two letters: OK.")],
                tools: nil
            )
            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let preview = String(text.prefix(50))
                lastTestResult = TestResult(success: true, message: "Connected. Response: \"\(preview)\"")
            } else {
                lastTestResult = TestResult(success: false, message: "Empty response from provider.")
            }
        } catch LLMClientError.missingAPIKey {
            lastTestResult = TestResult(success: false, message: "No API key configured for the selected provider.")
        } catch LLMClientError.unauthorized {
            lastTestResult = TestResult(success: false, message: "Unauthorized — the API key was rejected.")
        } catch LLMClientError.rateLimited {
            lastTestResult = TestResult(success: false, message: "Rate-limited. Try again shortly.")
        } catch {
            lastTestResult = TestResult(success: false, message: "Failed: \(error.localizedDescription)")
        }
    }
}
