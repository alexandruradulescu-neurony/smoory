import Foundation
import SwiftData

/// Bridges firing morning_brief ScheduledActions to MorningBriefGenerator. Called from:
/// 1. SmooryApp's polling tick after processOverdue, so any newly-fired briefs run
///    immediately if the app is open.
/// 2. NotificationDelegate when the user taps the morning_brief notification, in case
///    the polling tick hasn't picked it up yet.
///
/// Single-flight per actionID — concurrent triggers (poll + tap) collapse into one
/// generation. The action transitions .firing → .completed only once.
@MainActor
final class MorningBriefDispatcher {
    private let generator: MorningBriefGenerator
    private let scheduledActionService: ScheduledActionService
    private let modelContainer: ModelContainer

    private var inFlight: Set<UUID> = []

    init(
        generator: MorningBriefGenerator,
        scheduledActionService: ScheduledActionService,
        modelContainer: ModelContainer
    ) {
        self.generator = generator
        self.scheduledActionService = scheduledActionService
        self.modelContainer = modelContainer
    }

    /// Finds firing morning-brief actions and dispatches each to the generator.
    /// Idempotent — already-completed actions are excluded; in-flight ones are skipped.
    func dispatchAllFiring() async {
        let firing = firingMorningBriefs()
        for action in firing {
            await dispatch(action: action)
        }
    }

    /// Single-action dispatch. Used by NotificationDelegate when the user taps the
    /// morning_brief notification.
    func dispatch(actionID: UUID) async {
        guard let action = lookup(id: actionID) else { return }
        guard action.kind == .morningBrief else { return }
        await dispatch(action: action)
    }

    private func dispatch(action: ScheduledAction) async {
        guard !inFlight.contains(action.id) else {
            print("[brief] dispatch skipped — \(action.id) already in flight")
            return
        }
        inFlight.insert(action.id)
        defer { inFlight.remove(action.id) }

        do {
            let elapsed = Date().timeIntervalSince(action.scheduledFor)
            let brief = try await generator.generate(forAction: action, now: Date())
            print("[brief] generated for \(action.id) — headline: \(brief.headline)")
            // Mark the ScheduledAction completed; this triggers regenerateNextOccurrence
            // which schedules tomorrow's morning brief.
            _ = try? await scheduledActionService.markCompleted(
                actionID: action.id,
                userResponseTime: elapsed
            )
        } catch {
            // Failure: row stays .firing. The user will see the failure notification
            // (fired by generator). Polling tick won't re-attempt automatically — they
            // can retry via Debug → Generate morning brief now, which calls dispatch
            // for the same firing action.
            print("[brief] generation failed for \(action.id): \(error)")
        }
    }

    private func firingMorningBriefs() -> [ScheduledAction] {
        let context = ModelContext(modelContainer)
        // Same client-side filter rationale as FeedItem — predicates can't access
        // enum.rawValue cleanly. Volume is ~1/day, fine to fetch all firing.
        let firingRaw = ScheduledActionStatus.firing.rawValue
        let descriptor = FetchDescriptor<ScheduledAction>(
            predicate: #Predicate { $0.statusRaw == firingRaw }
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.filter { $0.kind == .morningBrief }
    }

    private func lookup(id: UUID) -> ScheduledAction? {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<ScheduledAction>(
            predicate: #Predicate { $0.id == id }
        )
        return (try? context.fetch(descriptor))?.first
    }
}
