import Foundation
import UserNotifications

struct NotificationStatus: Hashable {
    let isAuthorized: Bool
    let description: String
}

enum NativeNotificationManager {
    static let frigateAlertCategory = "APEX_FRIGATE_ALERT"
    static let viewLiveAction = "APEX_VIEW_LIVE"
    static let openReviewAction = "APEX_OPEN_REVIEW"
    static let markReviewedAction = "APEX_MARK_REVIEWED"
    static let snoozeCameraAction = "APEX_SNOOZE_CAMERA"

    static func registerCategories() {
        let viewLive = UNNotificationAction(
            identifier: viewLiveAction,
            title: "View Live",
            options: [.foreground]
        )
        let review = UNNotificationAction(
            identifier: openReviewAction,
            title: "Review",
            options: [.foreground]
        )
        let silence = UNNotificationAction(
            identifier: snoozeCameraAction,
            title: "Silence 1 hr",
            options: []
        )
        let markReviewed = UNNotificationAction(
            identifier: markReviewedAction,
            title: "Mark Reviewed",
            options: []
        )

        let category = UNNotificationCategory(
            identifier: frigateAlertCategory,
            actions: [viewLive, review, silence, markReviewed],
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
            "kind": "frigate-review",
            "camera": "front_porch",
            "apex_url": "apex://review"
        ]

        let request = UNNotificationRequest(
            identifier: "apex-test-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        try await UNUserNotificationCenter.current().add(request)
    }
}
