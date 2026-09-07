import BackgroundTasks
import Foundation
import os
import UserNotifications

/// Best-effort background polling for new alert reviews when the app is not running.
/// Stock Frigate cannot push to APNs, so this BGAppRefreshTask is the zero-config
/// baseline: iOS wakes the app periodically, we fetch recent reviews, and fire local
/// notifications for any new alert-severity items. Instant delivery requires the
/// optional push companion (see PushCompanionSettingsView).
enum BackgroundRefreshManager {
    static let taskIdentifier = "com.brandontoth.apexsight.refresh"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            handle(task: refreshTask)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(task: BGAppRefreshTask) {
        schedule() // always queue the next run

        // Complete the task EXACTLY once. Cancelling `work` on expiration doesn't stop
        // `performRefresh` (it swallows cancellation via `try?`), so without this guard the
        // work Task's `setTaskCompleted(true)` would fire a SECOND completion after the
        // expiration handler already completed it — a BackgroundTasks assertion that gets the
        // app throttled by the scheduler.
        let completed = OSAllocatedUnfairLock(initialState: false)
        func complete(success: Bool) {
            let firstToComplete = completed.withLock { done -> Bool in
                guard !done else { return false }
                done = true
                return true
            }
            if firstToComplete { task.setTaskCompleted(success: success) }
        }

        let work = Task {
            await performRefresh()
            complete(success: true)
        }

        task.expirationHandler = {
            work.cancel()
            complete(success: false)
        }
    }

    /// Loads the saved session directly (no live AppState), fetches recent reviews,
    /// and notifies for new alert items not yet seen. Kept intentionally small.
    static func performRefresh() async {
        guard var session = KeychainStore().loadSession() else { return }
        var client = FrigateClient(session: session)

        // Pull a wider window than before: a busy stretch (or a long gap between
        // background wakeups) can produce more than 20 reviews, and the older ones
        // would otherwise be skipped entirely.
        var reviews = try? await client.reviews(limit: 50, reviewed: false)

        // The token may have expired since the app last ran. Re-login once with the
        // stored credentials, refresh the shared token (so the notification
        // extension can still authenticate snapshot/GIF downloads), and retry.
        if reviews == nil, let refreshed = await reauthenticate(from: session) {
            session = refreshed
            client = FrigateClient(session: session)
            reviews = try? await client.reviews(limit: 50, reviewed: false)
        }

        guard let reviews else { return }

        let prefs = await NotificationPreferencesStore()
        let triggers = await NotificationTriggerStore().triggers
        // If instant push is set up, the relay already delivered these — don't post a
        // duplicate local notification. We still mark them seen so that, if push is
        // ever turned off later, we don't suddenly dump the whole backlog.
        let remotePush = DeviceTokenStore.hasRemotePush

        for review in reviews where review.severity == "alert" {
            guard LastSeenStore.isNew(review.id) else { continue }

            // Relay already delivered these — record seen (not a drop) so a later push-off doesn't
            // dump the whole backlog at once.
            if remotePush { LastSeenStore.markSeen([review.id]); continue }

            let label = review.data?.objects?.first ?? "object"
            let zones = review.data?.zones ?? []
            // Deliberately suppressed by the user's own rules — mark seen; this is a choice, not a drop.
            guard await prefs.shouldDeliver(
                camera: review.camera, label: label, zones: zones,
                score: 0, triggers: triggers
            ) else { LastSeenStore.markSeen([review.id]); continue }

            await LocalAlertNotifier.notify(review: review, client: client, session: session)
            // Mark seen only AFTER a successful post. If the BGTask's expiration handler cancels us
            // mid-`notify`, the review stays "new" and re-delivers next run — a rare duplicate, which
            // for a home-security alert is the right side of the fail-open rule (deliver when
            // uncertain) versus silently dropping the alert by stamping it seen before delivery.
            LastSeenStore.markSeen([review.id])
        }

    }


    /// Silent re-login from a background task (no live AppState available). Re-runs the
    /// stored login, persists the fresh session, and mirrors the new token into the app
    /// group so the notification service extension's fallback auth stays valid too.
    private static func reauthenticate(from session: FrigateSession) async -> FrigateSession? {
        guard let password = session.password, !password.isEmpty else { return nil }
        let loginClient = FrigateClient(baseURL: session.baseURL)
        guard let token = try? await loginClient.login(username: session.username, password: password) else {
            return nil
        }
        let next = FrigateSession(
            baseURL: session.baseURL,
            username: session.username,
            token: token,
            password: password,
            // Carry the home-network URL through, exactly as the foreground reauth does.
            // Omitting it defaulted the field to nil and this save persisted that over the real
            // session, so the next cold launch had no LAN address: evaluateLocalNetwork() bailed
            // immediately, onLocalNetwork could never become true, and every stream/snapshot/REST
            // call went out over the tunnel while standing at home.
            localBaseURL: session.localBaseURL
        )
        KeychainStore().save(session: next)
        let defaults = UserDefaults(suiteName: ApexAppGroup.identifier)
        // Token BEFORE url — same ordering as AppState.mirrorSessionToAppGroup and for the same
        // reason: every reader (NSE, widgets) reads the URL first, then the token, so writing the
        // token first means a reader landing between these two writes sees the harmless "old url +
        // new token" pairing (rejected by the old server) rather than "new url + old token".
        SharedTokenStore.save(token)
        defaults?.set(next.baseURL.absoluteString, forKey: "apex.frigateBaseURL")
        defaults?.removeObject(forKey: "apex.frigateToken")
        return next
    }
}
