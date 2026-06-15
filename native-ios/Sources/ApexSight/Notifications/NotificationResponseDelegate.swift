import Foundation
import SwiftUI
import UserNotifications

final class NotificationResponseDelegate: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @MainActor private weak var appState: AppState?

    override init() {
        super.init()
        // Register as delegate immediately so cold-launch notification taps are
        // captured before the SwiftUI view hierarchy mounts (.onAppear fires too late).
        UNUserNotificationCenter.current().delegate = self
    }

    @MainActor
    func configure(appState: AppState) {
        self.appState = appState
        // Delegate already registered in init(); this just wires the appState reference.
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        // Call completionHandler immediately — the system imposes a tight deadline
        // and will log an error if it's called after an async network round-trip.
        // Deep-link navigation and mark-reviewed fire-and-forget after returning.
        completionHandler()
        Task { @MainActor in
            await handle(response: response, userInfo: userInfo)
        }
    }

    // Show banners/sounds even when the app is foregrounded.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    @MainActor
    private func handle(response: UNNotificationResponse, userInfo: [AnyHashable: Any]) async {
        guard let appState else { return }

        if response.actionIdentifier == NativeNotificationManager.markReviewedAction,
           let reviewID = userInfo["review_id"] as? String {
            await appState.markReviewViewed(id: reviewID)
            return
        }

        if response.actionIdentifier == NativeNotificationManager.snoozeCameraAction,
           let camera = userInfo["camera"] as? String {
            appState.notificationPrefs.snooze(camera: camera, minutes: 60)
            return
        }

        if let urlString = userInfo["apex_url"] as? String, let url = URL(string: urlString) {
            appState.handleDeepLink(url)
            return
        }

        if let reviewID = userInfo["review_id"] as? String {
            appState.deepLink = .review(reviewID)
        } else if let eventID = userInfo["event_id"] as? String {
            appState.deepLink = .event(eventID)
        } else if let camera = userInfo["camera"] as? String {
            appState.deepLink = .camera(camera)
        }
    }
}
