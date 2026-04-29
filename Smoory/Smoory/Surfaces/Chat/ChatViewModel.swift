import Foundation
import Observation

@Observable
@MainActor
final class ChatViewModel {
    struct Turn: Identifiable, Hashable {
        enum Speaker: Sendable, Hashable { case user, assistant, errorBubble }
        let id: UUID
        let speaker: Speaker
        let text: String
    }

    enum TurnState: Sendable, Hashable {
        case idle
        case sending
    }

    private(set) var turns: [Turn] = []
    private(set) var state: TurnState = .idle
    var draft: String = ""

    private let client: LLMClient
    private let systemPrompt = """
You are Smoory, a helpful assistant running on the user's Mac. This is a Phase 1 development build — no memory, no tools, no structured context yet. Be conversational, concise, and honest that you don't yet have the full Smoory features wired up.
"""

    init(client: LLMClient = AnthropicClient()) {
        self.client = client
    }

    func send() async {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, state != .sending else { return }

        let userTurn = Turn(id: UUID(), speaker: .user, text: trimmed)
        turns.append(userTurn)
        draft = ""
        state = .sending

        let history = Self.buildHistory(from: turns)

        do {
            let response = try await client.complete(
                model: .balanced,
                systemPrompt: systemPrompt,
                messages: history,
                tools: nil
            )
            turns.append(Turn(id: UUID(), speaker: .assistant, text: response.text))
        } catch {
            turns.append(Turn(id: UUID(), speaker: .errorBubble, text: Self.friendlyMessage(for: error)))
        }
        state = .idle
    }

    /// Build the API-shape history from UI turns. Filters out error bubbles
    /// (UI-only) and collapses any consecutive same-role messages into the
    /// most recent — Anthropic requires strict user/assistant alternation
    /// and a failed turn leaves the history with two user messages in a row.
    private static func buildHistory(from turns: [Turn]) -> [LLMMessage] {
        var history: [LLMMessage] = []
        for turn in turns where turn.speaker != .errorBubble {
            let role: LLMMessage.Role = (turn.speaker == .user) ? .user : .assistant
            let message = LLMMessage(role: role, content: turn.text)
            if history.last?.role == role {
                history[history.count - 1] = message
            } else {
                history.append(message)
            }
        }
        return history
    }

    private static func friendlyMessage(for error: Error) -> String {
        if let llmError = error as? LLMClientError {
            switch llmError {
            case .missingAPIKey:
                return "No Anthropic API key configured. Add one in Settings."
            case .unauthorized:
                return "The API key in Settings looks invalid. Replace it in Settings."
            case .rateLimited:
                return "Anthropic is rate-limiting requests. Try again in a moment."
            case .server(let status, _):
                return "Anthropic returned a server error (\(status)). Try again shortly."
            case .network:
                return "Network problem. Check your connection and try again."
            case .invalidResponse, .decoding:
                return "Got an unexpected response from Anthropic. This is likely a Smoory bug."
            case .unknown:
                return "Something went wrong. Try again."
            }
        }
        return error.localizedDescription
    }
}
