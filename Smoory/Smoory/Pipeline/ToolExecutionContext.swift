import Foundation
import SwiftData

/// Sendable bag of services every tool's execute receives. The orchestrator constructs a fresh
/// context per tool dispatch (toolUseId varies); chatSessionID and services come from the
/// orchestrator's longer-lived state.
struct ToolExecutionContext: Sendable {
    let toolUseId: String
    let chatSessionID: UUID
    let services: ToolServices
}

/// Long-lived services shared across all tool invocations within a session.
/// Tools that need a SwiftData ModelContext create a fresh one from `modelContainer` —
/// ModelContext is not Sendable, but ModelContainer is, so we share the container and
/// each tool spawns its own context on the thread it runs on.
struct ToolServices: Sendable {
    let calendarService: CalendarService
    let modelContainer: ModelContainer
    let hema: HemaService
}
