import Foundation
import SwiftUI
import UIKit
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
        let action = response.actionIdentifier

        // Background actions (no .foreground option) do network/state work and must NOT depend on
        // appState (which may not exist when iOS launches us in the background just for the action)
        // or call completionHandler() before that work finishes (iOS would suspend us mid-request).
        if action == NativeNotificationManager.markReviewedAction
            || action == NativeNotificationManager.snoozeCameraAction {
            Task { @MainActor in
                let app = UIApplication.shared
                var bgTask: UIBackgroundTaskIdentifier = .invalid
                bgTask = app.beginBackgroundTask {
                    if bgTask != .invalid { app.endBackgroundTask(bgTask); bgTask = .invalid }
                }
                await Self.handleBackgroundAction(action: action, userInfo: userInfo)
                completionHandler()
                if bgTask != .invalid { app.endBackgroundTask(bgTask); bgTask = .invalid }
            }
            return
        }

        // Foreground / deep-link taps: the app is (being) foregrounded, so return immediately and
        // navigate via appState once it's available.
        completionHandler()
        Task { @MainActor in
            await handle(response: response, userInfo: userInfo)
        }
    }

    /// Runs without an AppState so it works even on a cold background launch. Snooze + mark-reviewed
    /// reach the relay / server directly via the shared stores and the keychain session.
    private static func handleBackgroundAction(action: String, userInfo: [AnyHashable: Any]) async {
        switch action {
        case NativeNotificationManager.snoozeCameraAction:
            // A real push is decided by the relay, which only knows the GLOBAL gate — so a
            // per-camera snooze would silently do nothing. Snooze everything for an hour and push
            // that gate to the relay so the button actually quiets alerts.
            let until = Date().addingTimeInterval(60 * 60)
            GlobalSnooze.snooze(until: until)
            await RelayGate.sync(snoozedUntil: until.timeIntervalSince1970)

        case NativeNotificationManager.markReviewedAction:
            guard let reviewID = userInfo["review_id"] as? String,
                  let session = KeychainStore().loadSession() else { return }
            try? await FrigateClient(session: session).markReviewsViewed(ids: [reviewID])
            // Reflect it on the app icon now (the app may never foreground to self-heal the badge).
            let defaults = UserDefaults(suiteName: ApexAppGroup.identifier)
            let next = max(0, (defaults?.integer(forKey: "apex.badgeCount") ?? 1) - 1)
            defaults?.set(next, forKey: "apex.badgeCount")
            try? await UNUserNotificationCenter.current().setBadgeCount(next)

        default:
            break
        }
    }

    // Foreground presentation policy.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let request = notification.request

        // Test pushes must always be visible — they exist to prove the pipeline.
        if request.identifier.hasPrefix("apex-test-") {
            completionHandler([.banner, .sound, .badge])
            return
        }

        // Our own just-posted local alert while the app is frontmost: the in-app glass
        // banner (+haptic) already covers it, so presenting the system banner + sound too
        // double-alerted every fallback-path alert. Keep it in Notification Center
        // (silent) so it's still there after leaving the app.
        if request.identifier.hasPrefix("apex-review-") {
            completionHandler([.list, .badge])
            return
        }

        // Relay pushes: the relay only knows the GLOBAL gate, so per-camera mutes,
        // Disarm, snoozes, and quiet hours were silent no-ops for pushes. Honor them
        // at presentation time — the app-side last chance while foregrounded.
        // (`wouldDeliver`, not `shouldDeliver`: presentation must not consume the
        // local-notification cooldown clock.)
        if let camera = request.content.userInfo["camera"] as? String {
            // The relay now mirrors the same object/zone/score fields its own per-device gate used
            // (apns.build_payload); without them this re-check could only ever honor camera-level
            // mutes, so a muted OBJECT or ZONE would still banner while the app was foregrounded.
            let label = request.content.userInfo["label"] as? String ?? "object"
            let zones = request.content.userInfo["zones"] as? [String] ?? []
            let score = request.content.userInfo["score"] as? Double ?? 0
            Task { @MainActor in
                let muted: Bool
                if let appState = self.appState {
                    muted = !appState.notificationPrefs.wouldDeliver(
                        camera: camera, label: label, zones: zones,
                        score: score, triggers: appState.triggerStore.triggers
                    )
                } else {
                    muted = false
                }
                completionHandler(muted ? [.list] : [.banner, .sound, .badge])
            }
            return
        }

        completionHandler([.banner, .sound, .badge])
    }

    @MainActor
    private func handle(response: UNNotificationResponse, userInfo: [AnyHashable: Any]) async {
        guard let appState else { return }

        // "View Live" — jump straight to the camera's live view.
        if response.actionIdentifier == NativeNotificationManager.viewLiveAction,
           let camera = userInfo["camera"] as? String {
            appState.deepLink = .camera(camera)
            return
        }

        // "Review" — open the review, else the deep link, else the camera. Explicit so
        // this action can never dead-end regardless of which fields the payload carries.
        if response.actionIdentifier == NativeNotificationManager.openReviewAction {
            if let reviewID = userInfo["review_id"] as? String {
                appState.deepLink = .review(reviewID)
            } else if let urlString = userInfo["apex_url"] as? String, let url = URL(string: urlString) {
                appState.handleDeepLink(url)
            } else if let camera = userInfo["camera"] as? String {
                appState.deepLink = .camera(camera)
            }
            return
        }

        // markReviewed / snooze are handled in handleBackgroundAction (they must run without
        // appState and defer the completion handler), so they never reach here.

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
