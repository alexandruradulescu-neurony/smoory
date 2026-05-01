import Observation

@Observable
@MainActor
final class PendingWeekReviewState {
    var actionToPresent: ScheduledAction?
}
