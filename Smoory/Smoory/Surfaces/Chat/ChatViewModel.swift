import Foundation
import Observation
import SwiftData

@Observable
@MainActor
final class ChatViewModel {
    struct Turn: Identifiable, Hashable {
        enum Speaker: Sendable, Hashable { case user, assistant, errorBubble }
        let id: UUID
        let speaker: Speaker
        let text: String
        let usedToolNames: [String]?     // dedup'd, only set on assistant turns that called tools
    }

    enum TurnState: Sendable, Hashable {
        case idle
        case sending
    }

    private(set) var turns: [Turn] = []
    private(set) var state: TurnState = .idle
    var draft: String = ""

    private let orchestrator: Orchestrator
    private let chatSessionID = UUID()
    private let systemPrompt = """
You are Smoory, a helpful assistant running on the user's Mac. This is a Phase 1 development build — no memory, no tools, no structured context yet. Be conversational, concise, and honest that you don't yet have the full Smoory features wired up.

You have tools available to read the user's calendar, goals, and todos. Use them when relevant. Don't narrate that you're using tools — just use them and answer.
"""

    init(
        modelContainer: ModelContainer,
        client: LLMClient = AnthropicClient(),
        calendarService: CalendarService = CalendarService()
    ) {
        let services = ToolServices(
            calendarService: calendarService,
            modelContainer: modelContainer
        )
        self.orchestrator = Orchestrator(
            client: client,
            registry: ToolRegistry.allTools,
            services: services,
            chatSessionID: chatSessionID
        )
    }

    func send() async {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, state != .sending else { return }

        let userTurn = Turn(id: UUID(), speaker: .user, text: trimmed, usedToolNames: nil)
        turns.append(userTurn)
        draft = ""
        state = .sending

        // Build history from prior turns. Filter out errorBubbles so a transient error doesn't
        // poison the next request. Exclude the just-appended userTurn — orchestrator.send takes
        // userMessage separately.
        let history: [LLMMessage] = turns
            .filter { $0.speaker != .errorBubble && $0.id != userTurn.id }
            .map { turn in
                let role: LLMMessage.Role = (turn.speaker == .user) ? .user : .assistant
                return LLMMessage(role: role, text: turn.text)
            }

        do {
            let result = try await orchestrator.send(
                systemPrompt: systemPrompt,
                history: history,
                userMessage: trimmed,
                modelTier: .balanced
            )

            switch result.stoppedReason {
            case .naturalEnd, .maxRoundsReached:
                let usedNames = Self.deduplicate(result.toolExchanges.map(\.toolName))
                let displayText = result.finalText.isEmpty ? "(empty response)" : result.finalText
                turns.append(Turn(
                    id: UUID(),
                    speaker: .assistant,
                    text: displayText,
                    usedToolNames: usedNames.isEmpty ? nil : usedNames
                ))
            case .clientError(let error):
                turns.append(Turn(
                    id: UUID(),
                    speaker: .errorBubble,
                    text: Self.friendlyMessage(for: error),
                    usedToolNames: nil
                ))
            case .toolError(let str):
                turns.append(Turn(
                    id: UUID(),
                    speaker: .errorBubble,
                    text: "Tool execution failed: \(str)",
                    usedToolNames: nil
                ))
            }
        } catch {
            turns.append(Turn(
                id: UUID(),
                speaker: .errorBubble,
                text: Self.friendlyMessage(for: error),
                usedToolNames: nil
            ))
        }
        state = .idle
    }

    private static func deduplicate(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
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
