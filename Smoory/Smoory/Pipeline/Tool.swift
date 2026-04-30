import Foundation
import SwiftData
import SwiftUI

/// A capability the LLM can invoke. Static-only protocol — tools are stateless types.
protocol Tool: Sendable {
    static var name: String { get }
    static var description: String { get }
    static var inputSchema: ToolInputSchema { get }
    static var confirmationTier: ConfirmationTier { get }

    static func execute(
        parametersJSON: String,
        context: ToolExecutionContext
    ) async throws -> ToolOutput

    /// Compact human-readable summary for confirmation cards. Default: nil (silent tools don't need this).
    static func renderSummary(parametersJSON: String) -> ProposedActionSummary?

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
    static func renderSummary(parametersJSON: String) -> ProposedActionSummary? { nil }

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
