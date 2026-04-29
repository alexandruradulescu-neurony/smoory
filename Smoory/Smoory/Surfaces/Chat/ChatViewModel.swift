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
    private let hema: HemaService
    private let chatSessionID: UUID

    private let systemPrompt = """
You are Smoory, a personal AI assistant for the user. You're running on the user's Mac.

You have access to:
- The user's calendar via get_calendar_window
- The user's active goals via get_active_goals
- The user's open todos via get_open_todos
- The user's memory of past conversations and learned facts via retrieve_memory

The compact summaries below are always-on. For specific past facts, names, or events, \
use retrieve_memory with a focused query.

Be conversational, concise, and honest about what you don't know. If memory retrieval \
returns nothing relevant, say so.
"""

    init(
        modelContainer: ModelContainer,
        hema: HemaService,
        chatSessionID: UUID,
        client: LLMClient = AnthropicClient(),
        calendarService: CalendarService = CalendarService()
    ) {
        self.hema = hema
        self.chatSessionID = chatSessionID
        let services = ToolServices(
            calendarService: calendarService,
            modelContainer: modelContainer,
            hema: hema
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

                // 2.2b: persist the conversational text to hema, off the critical path.
                // Errors aren't conversational content; only the success branch persists.
                let userMessageToPersist = trimmed
                let assistantTextToPersist = result.finalText
                Task {
                    await self.persistTurns(
                        userMessage: userMessageToPersist,
                        assistantReply: assistantTextToPersist
                    )
                }

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

    /// Writes the conversational pair to hema. Tool-use / tool-result blocks are NOT persisted —
    /// they're not user-meaningful conversational content and would pollute vector retrieval.
    /// Failures are logged but never surface to the chat — memory write outages should not
    /// disrupt the conversation.
    private func persistTurns(userMessage: String, assistantReply: String) async {
        do {
            try await hema.writeTurn(MemoryTurn(
                id: UUID(),
                createdAt: Date(),
                chatSessionID: chatSessionID,
                role: .user,
                content: userMessage,
                metadataJSON: nil,
                vector: nil
            ))
            if !assistantReply.isEmpty {
                try await hema.writeTurn(MemoryTurn(
                    id: UUID(),
                    createdAt: Date(),
                    chatSessionID: chatSessionID,
                    role: .assistant,
                    content: assistantReply,
                    metadataJSON: nil,
                    vector: nil
                ))
            }
        } catch {
            print("[chat] hema write failed: \(error)")
        }
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
