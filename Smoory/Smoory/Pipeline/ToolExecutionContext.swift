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
    /// Optional because chat construction precedes ScheduledActionService bring-up in some
    /// startup orderings; tools that need it must guard before use.
    let scheduledActionService: ScheduledActionService?
    /// Optional batched fact extractor (4.4). CompleteDayReviewTool uses it to
    /// pre-extract facts from the day's chat turns before the day-review
    /// summary turn is persisted. Optional because some startup paths
    /// construct ToolServices before hema is fully ready.
    let batchedFactExtractor: BatchedFactExtractor?
    /// Optional fact restructurer (4.5). CompleteDayReviewTool fires it AFTER
    /// the batched extractor so the restructurer's input includes any facts
    /// freshly extracted during the same day-review pass.
    let factRestructurer: FactRestructurer?

    init(
        calendarService: CalendarService,
        modelContainer: ModelContainer,
        hema: HemaService,
        scheduledActionService: ScheduledActionService? = nil,
        batchedFactExtractor: BatchedFactExtractor? = nil,
        factRestructurer: FactRestructurer? = nil
    ) {
        self.calendarService = calendarService
        self.modelContainer = modelContainer
        self.hema = hema
        self.scheduledActionService = scheduledActionService
        self.batchedFactExtractor = batchedFactExtractor
        self.factRestructurer = factRestructurer
    }
}
