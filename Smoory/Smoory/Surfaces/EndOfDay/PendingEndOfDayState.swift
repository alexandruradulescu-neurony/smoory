import Observation

/// 4.10 — bridge between NotificationDelegate (which receives notification taps)
/// and SmooryApp (which presents the sheet). Mirror of `PendingDayReviewState`.
@Observable
@MainActor
final class PendingEndOfDayState {
    var actionToPresent: ScheduledAction?
}
