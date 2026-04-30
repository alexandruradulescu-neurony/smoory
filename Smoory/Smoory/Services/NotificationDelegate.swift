import Foundation
import UserNotifications

/// UNUserNotificationCenterDelegate that routes user responses (tap, action button)
/// back into ScheduledActionService. Held by SmooryApp at app level.
@MainActor
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private weak var service: ScheduledActionService?
    private weak var pendingDayReview: PendingDayReviewState?
    private weak var firedReminderQueue: FiredReminderQueue?
    private weak var navigationState: NavigationState?
    private weak var morningBriefDispatcher: MorningBriefDispatcher?

    func attach(
        service: ScheduledActionService,
        pendingDayReview: PendingDayReviewState,
        firedReminderQueue: FiredReminderQueue,
        navigationState: NavigationState,
        morningBriefDispatcher: MorningBriefDispatcher
    ) {
        self.service = service
        self.pendingDayReview = pendingDayReview
        self.firedReminderQueue = firedReminderQueue
        self.navigationState = navigationState
        self.morningBriefDispatcher = morningBriefDispatcher
        UNUserNotificationCenter.current().delegate = self
    }

    /// Allow banner + sound while the app is foreground; otherwise macOS suppresses
    /// the notification and the user never sees it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let actionID = (userInfo["actionID"] as? String).flatMap(UUID.init(uuidString:))
        let identifier = response.actionIdentifier
        Task { @MainActor in
            await self.handle(actionIdentifier: identifier, actionID: actionID)
            completionHandler()
        }
    }

    private func handle(actionIdentifier: String, actionID: UUID?) async {
        guard let service else {
            print("[notif] no service attached; dropping response \(actionIdentifier)")
            return
        }
        guard let actionID else {
            print("[notif] notification response missing actionID userInfo")
            return
        }

        switch actionIdentifier {
        case NotificationCategoryRegistrar.actionPostpone1h:
            do {
                _ = try await service.postpone(actionID: actionID, by: 3600, reason: "notification-postpone")
                print("[notif] postponed \(actionID) by 1h")
            } catch {
                print("[notif] postpone failed: \(error)")
            }

        case NotificationCategoryRegistrar.actionSkip:
            do {
                try await service.skipThisOccurrence(actionID: actionID)
                print("[notif] skipped \(actionID)")
            } catch {
                print("[notif] skip failed: \(error)")
            }

        case NotificationCategoryRegistrar.actionNow,
             UNNotificationDefaultActionIdentifier:
            // Flip the row to .firing (idempotent if processOverdue already did it),
            // then route by kind. dayReview opens the modal sheet via PendingDayReviewState.
            // Other kinds log + leave the row in .firing for their future consumers.
            _ = try? service.markFiring(actionID: actionID)
            await routeFiringActionToConsumer(id: actionID, service: service)

        case UNNotificationDismissActionIdentifier:
            // User swiped away the notification without acting. Leave row as-is; it
            // stays .pending and the next polling tick will re-evaluate when its
            // scheduledFor passes.
            print("[notif] dismissed \(actionID)")

        default:
            print("[notif] unknown actionIdentifier=\(actionIdentifier) for \(actionID)")
        }
    }

    /// Looks up the row in SwiftData and dispatches to the correct consumer. Currently
    /// only .dayReview has a UI consumer (modal sheet); other kinds wait for their
    /// future consumer milestones.
    private func routeFiringActionToConsumer(id: UUID, service: ScheduledActionService) async {
        let history = (try? service.actionsHistory(daysBack: 1)) ?? []
        guard let row = history.first(where: { $0.id == id }) else {
            print("[notif] couldn't find action \(id) for routing")
            return
        }
        switch row.kind {
        case .dayReview:
            guard let pending = pendingDayReview else {
                print("[notif] dayReview tapped but PendingDayReviewState not attached")
                return
            }
            pending.actionToPresent = row
            print("[notif] presenting day review for \(id)")

        case .userReminder:
            guard let queue = firedReminderQueue else {
                print("[notif] userReminder tapped but FiredReminderQueue not attached")
                return
            }
            queue.enqueue(action: row)
            print("[notif] enqueued reminder banner for \(id)")

        case .morningBrief:
            navigationState?.selectedSurface = .feed
            print("[notif] morning brief tapped — focusing Feed")
            // If the brief hasn't been generated yet (user tapped before polling tick
            // picked it up), trigger generation now. Single-flight in dispatcher
            // collapses concurrent triggers.
            if let dispatcher = morningBriefDispatcher {
                Task { @MainActor in await dispatcher.dispatch(actionID: id) }
            }

        case .weekReview, .goalNudge:
            print("[notif] kind=\(row.kind) tapped — no consumer wired yet for this kind")
        }
    }
}
