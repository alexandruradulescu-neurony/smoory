import Foundation
import SwiftData

@Model
final class ChatMessage {
    var id: UUID = UUID()
    var role: ChatRole = ChatRole.user
    var content: String = ""
    var toolCalls: [ToolCall] = []
    var toolResults: [ToolResult] = []
    var inlineProposedActions: [ProposedAction] = []
    var relatedFeedItem: FeedItem?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    @Relationship(inverse: \CaptureItem.attachedToMessage)
    var attachments: [CaptureItem] = []

    init() {}
}
