import Foundation
import UserNotifications

struct NotificationStatus: Hashable {
    let isAuthorized: Bool
    let description: String
}

enum NativeNotificationManager {
    static let frigateAlertCategory = "APEX_FRIGATE_ALERT"
    static let openReviewAction = "APEX_OPEN_REVIEW"
    static let markReviewedAction = "APEX_MARK_REVIEWED"
    static let snoozeCameraAction = "APEX_SNOOZE_CAMERA"

    static func registerCategories() {
        let openReview = UNNotificationAction(
            identifier: openReviewAction,
            title: "Open",
            options: [.foreground]
        )
        let markReviewed = UNNotificationAction(
            identifier: markReviewedAction,
            title: "Reviewed",
            options: []
        )
        let snooze = UNNotificationAction(
            identifier: snoozeCameraAction,
            title: "Snooze",
            options: []
        )

        let category = UNNotificationCategory(
            identifier: frigateAlertCategory,
            actions: [openReview, markReviewed, snooze],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    static func status() async -> NotificationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized:
            return NotificationStatus(isAuthorized: true, description: "Allowed")
        case .provisional:
            return NotificationStatus(isAuthorized: true, description: "Quiet")
        case .denied:
            return NotificationStatus(isAuthorized: false, description: "Denied")
        case .notDetermined:
            return NotificationStatus(isAuthorized: false, description: "Not Set")
        case .ephemeral:
            return NotificationStatus(isAuthorized: true, description: "Temporary")
        @unknown default:
            return NotificationStatus(isAuthorized: false, description: "Unknown")
        }
    }

    static func requestPermission() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }

    static func sendTestNotification() async throws {
        let content = UNMutableNotificationContent()
        content.title = "🧍 Person detected"
        content.body = "Front Porch • 94% confidence • Zone: Walkway"
        content.sound = .default
        content.threadIdentifier = "apex-test-alert"
        content.categoryIdentifier = frigateAlertCategory
        content.userInfo = [
            "source": "apex-test",
            "kind": "frigate-review"
        ]

        let request = UNNotificationRequest(
            identifier: "apex-test-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        try await UNUserNotificationCenter.current().add(request)
    }
}
