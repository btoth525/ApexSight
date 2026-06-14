import Foundation
import SwiftUI
import UserNotifications

final class NotificationResponseDelegate: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @MainActor private weak var appState: AppState?

    @MainActor
    func configure(appState: AppState) {
        self.appState = appState
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            await handle(response: response, userInfo: userInfo)
            completionHandler()
        }
    }

    @MainActor
    private func handle(response: UNNotificationResponse, userInfo: [AnyHashable: Any]) async {
        guard let appState else { return }

        if response.actionIdentifier == NativeNotificationManager.markReviewedAction,
           let reviewID = userInfo["review_id"] as? String {
            await appState.markReviewViewed(id: reviewID)
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
