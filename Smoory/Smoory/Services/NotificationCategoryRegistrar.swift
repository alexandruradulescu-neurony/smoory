import Foundation
import UserNotifications

/// One-shot registration of the SMOORY_SCHEDULED_ACTION category so action buttons
/// (Now / Postpone 1h / Skip) appear when the user long-presses a notification.
enum NotificationCategoryRegistrar {
    static let categoryID = "SMOORY_SCHEDULED_ACTION"
    static let actionNow = "NOW"
    static let actionPostpone1h = "POSTPONE_1H"
    static let actionSkip = "SKIP"

    static func register() {
        let now = UNNotificationAction(
            identifier: actionNow,
            title: "Now",
            options: [.foreground]
        )
        let postpone = UNNotificationAction(
            identifier: actionPostpone1h,
            title: "Postpone 1h",
            options: []
        )
        let skip = UNNotificationAction(
            identifier: actionSkip,
            title: "Skip",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: [now, postpone, skip],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}
