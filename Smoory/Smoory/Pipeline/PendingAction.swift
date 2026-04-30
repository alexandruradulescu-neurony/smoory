import Foundation

enum PendingActionState: Sendable, Hashable {
    case pending
    case editing
    case executing
    case confirmed(summary: String)
    case declined(summary: String)
    case failed(reason: String)
}

struct PendingAction: Identifiable, Sendable, Hashable {
    let id: String                       // tool_use_id from Anthropic
    let toolName: String
    let parametersJSON: String           // original from Claude
    var editedParametersJSON: String?    // nil unless user committed an edit
    let confirmationTier: ConfirmationTier
    let proposedAt: Date
    var state: PendingActionState
    let assistantTurnID: UUID            // placeholder turn this card is parented to

    var effectiveParametersJSON: String { editedParametersJSON ?? parametersJSON }
    var wasEdited: Bool { editedParametersJSON != nil }
}

/// Human-readable summary built from a tool's parametersJSON, used by the confirmation card.
struct ProposedActionSummary: Sendable, Hashable {
    let icon: String                     // SF Symbol
    let title: String                    // e.g. "Create todo"
    let primary: String                  // e.g. "Call the dentist"
    let secondary: String?               // e.g. "Tomorrow • normal priority"
}

/// Implemented by ChatViewModel. Orchestrator awaits this for non-silent tools.
protocol OrchestratorDelegate: AnyObject, Sendable {
    @MainActor
    func handlePendingAction(
        toolName: String,
        parametersJSON: String,
        toolUseId: String,
        confirmationTier: ConfirmationTier,
        assistantTurnID: UUID
    ) async -> ToolOutput
}
