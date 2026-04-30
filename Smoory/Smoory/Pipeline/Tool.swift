import Foundation
import SwiftData
import SwiftUI

/// A capability the LLM can invoke. Static-only protocol — tools are stateless types.
protocol Tool: Sendable {
    static var name: String { get }
    static var description: String { get }
    static var inputSchema: ToolInputSchema { get }
    static var confirmationTier: ConfirmationTier { get }

    /// True if the confirmation card's Edit button should be shown.
    /// Tools with no editable fields (complete_todo, delete_todo) override to false.
    static var supportsEditing: Bool { get }

    static func execute(
        parametersJSON: String,
        context: ToolExecutionContext
    ) async throws -> ToolOutput

    /// Compact human-readable summary for confirmation cards. Default: nil (silent tools don't need this).
    /// Receives the model container so summaries can look up entity titles by id.
    static func renderSummary(
        parametersJSON: String,
        modelContainer: ModelContainer
    ) -> ProposedActionSummary?

    /// Edit form shown when the user taps Edit on a card. Default: empty (silent tools don't need this).
    @MainActor
    static func makeEditView(
        parametersJSON: String,
        modelContainer: ModelContainer,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) -> AnyView
}

extension Tool {
    static var supportsEditing: Bool { true }

    static func renderSummary(parametersJSON: String, modelContainer: ModelContainer) -> ProposedActionSummary? { nil }

    @MainActor
    static func makeEditView(
        parametersJSON: String,
        modelContainer: ModelContainer,
        onCommit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) -> AnyView {
        AnyView(EmptyView())
    }
}

struct ToolInputSchema: Codable, Sendable, Hashable {
    let type: String                                        // always "object"
    let properties: [String: ToolInputSchemaProperty]
    let required: [String]

    init(
        type: String = "object",
        properties: [String: ToolInputSchemaProperty],
        required: [String]
    ) {
        self.type = type
        self.properties = properties
        self.required = required
    }
}

struct ToolInputSchemaProperty: Codable, Sendable, Hashable {
    let type: String
    let description: String?
    let items: ToolInputSchemaItem?

    init(type: String, description: String?, items: ToolInputSchemaItem? = nil) {
        self.type = type
        self.description = description
        self.items = items
    }
}

struct ToolInputSchemaItem: Codable, Sendable, Hashable {
    let type: String
}

struct ToolOutput: Sendable, Hashable, Codable {
    let toolUseId: String
    let content: String
    let isError: Bool
}
