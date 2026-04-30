import Observation

/// Bridge between NotificationDelegate (which receives notification taps) and
/// SmooryApp (which presents the sheet). Single mutable optional — simpler than
/// a queue, and per the milestone-prompt scope only the most recent firing
/// action is presented. If a tap comes in while a sheet is already up, the new
/// value is set but `.sheet` won't re-present until the current one dismisses.
@Observable
@MainActor
final class PendingDayReviewState {
    var actionToPresent: ScheduledAction?
}
