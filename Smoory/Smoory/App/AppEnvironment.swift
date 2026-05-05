import Foundation
import SwiftUI

/// Environment value carrying the app-level HemaService state. ChatView reads this to gate on
/// memory readiness. Default `.loading` is harmless — SmooryApp always sets the real value.
private struct HemaStateKey: EnvironmentKey {
    static let defaultValue: HemaState = .loading
}

/// Environment value for the chat session UUID — stable across the app's lifetime so
/// navigating Sidebar away and back doesn't reset the session.
private struct ChatSessionIDKey: EnvironmentKey {
    static let defaultValue: UUID = UUID()
}

private struct ChatViewModelKey: EnvironmentKey {
    static let defaultValue: ChatViewModel? = nil
}

private struct ScheduledActionServiceKey: EnvironmentKey {
    static let defaultValue: ScheduledActionService? = nil
}

private struct NavigationStateKey: EnvironmentKey {
    static let defaultValue: NavigationState? = nil
}

private struct RemindersSyncKey: EnvironmentKey {
    static let defaultValue: RemindersSyncService? = nil
}

private struct VoiceCaptureKey: EnvironmentKey {
    static let defaultValue: VoiceCaptureService? = nil
}

/// F-23 audit fix: env-injected error toast bus so every mutation handler can
/// surface failures with a single line. Default-nil so previews / tests that
/// don't inject still work; sites read it as `Environment(\.errorBus)?.report(...)`.
private struct ErrorBusKey: EnvironmentKey {
    static let defaultValue: ErrorBus? = nil
}

/// Env-injected pending-review states. SmooryApp owns the @State instances and
/// drives the .sheet binding off them; FeedView's "Reviews" surface taps set
/// `.actionToPresent` to open the corresponding review modal.
private struct PendingDayReviewStateKey: EnvironmentKey {
    static let defaultValue: PendingDayReviewState? = nil
}

private struct PendingWeekReviewStateKey: EnvironmentKey {
    static let defaultValue: PendingWeekReviewState? = nil
}

private struct PendingEndOfDayStateKey: EnvironmentKey {
    static let defaultValue: PendingEndOfDayState? = nil
}

extension EnvironmentValues {
    var hemaState: HemaState {
        get { self[HemaStateKey.self] }
        set { self[HemaStateKey.self] = newValue }
    }
    var chatSessionID: UUID {
        get { self[ChatSessionIDKey.self] }
        set { self[ChatSessionIDKey.self] = newValue }
    }
    /// App-level ChatViewModel — persists across sidebar navigation so chat history survives.
    var chatViewModel: ChatViewModel? {
        get { self[ChatViewModelKey.self] }
        set { self[ChatViewModelKey.self] = newValue }
    }
    /// App-level ScheduledActionService — Settings reads this to drive the day-review toggle.
    var scheduledActionService: ScheduledActionService? {
        get { self[ScheduledActionServiceKey.self] }
        set { self[ScheduledActionServiceKey.self] = newValue }
    }
    /// App-level navigation state — lifted from ContentView so the notification delegate
    /// can imperatively switch surfaces (morning-brief tap → focus Feed).
    var navigationState: NavigationState? {
        get { self[NavigationStateKey.self] }
        set { self[NavigationStateKey.self] = newValue }
    }
    /// App-level Reminders.app sync service (4.7). ListsView and SettingsView read this
    /// to drive the opt-in toggle and the manual "Sync now" button. nil when the app
    /// hasn't yet stood the service up (pre-hema or in tests).
    var remindersSyncService: RemindersSyncService? {
        get { self[RemindersSyncKey.self] }
        set { self[RemindersSyncKey.self] = newValue }
    }
    /// App-level voice-dictation service (4.11). Review sheets + main chat read this
    /// to drive the mic button. Single shared instance; only one capture session can
    /// be active at a time.
    var voiceCaptureService: VoiceCaptureService? {
        get { self[VoiceCaptureKey.self] }
        set { self[VoiceCaptureKey.self] = newValue }
    }
    /// App-level ErrorBus (F-23 audit fix). Mutation handlers across surfaces report
    /// caught errors to this bus instead of `print`-and-swallow; ContentView renders
    /// the active toast as a top-anchored banner.
    var errorBus: ErrorBus? {
        get { self[ErrorBusKey.self] }
        set { self[ErrorBusKey.self] = newValue }
    }
    /// Pending-review states. FeedView's "Reviews" surface reads these to present
    /// the corresponding review sheet on tap, mirroring NotificationDelegate's
    /// notification-tap path.
    var pendingDayReview: PendingDayReviewState? {
        get { self[PendingDayReviewStateKey.self] }
        set { self[PendingDayReviewStateKey.self] = newValue }
    }
    var pendingWeekReview: PendingWeekReviewState? {
        get { self[PendingWeekReviewStateKey.self] }
        set { self[PendingWeekReviewStateKey.self] = newValue }
    }
    var pendingEndOfDay: PendingEndOfDayState? {
        get { self[PendingEndOfDayStateKey.self] }
        set { self[PendingEndOfDayStateKey.self] = newValue }
    }
}
