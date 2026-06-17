import BackgroundTasks
import Foundation
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

        let work = Task {
            await performRefresh()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
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
            // Mark seen immediately so a mid-task cancellation can't re-deliver on the next run.
            LastSeenStore.markSeen([review.id])

            if remotePush { continue }

            let label = review.data?.objects?.first ?? "object"
            let zones = review.data?.zones ?? []
            guard await prefs.shouldDeliver(
                camera: review.camera, label: label, zones: zones,
                score: 0, triggers: triggers
            ) else { continue }

            await LocalAlertNotifier.notify(review: review, client: client, session: session)
        }

        await maybeSendRecap(client: client)
    }

    /// Posts the once-a-day recap notification when it's at/after the user's chosen
    /// time and today's hasn't gone out yet. Independent of the alert path.
    private static func maybeSendRecap(client: FrigateClient) async {
        guard RecapSettings.shouldSendNow() else { return }
        // When instant push is set up, the relay sends the daily recap (reliable even
        // with the app fully closed) — skip the local one so it isn't duplicated.
        guard !DeviceTokenStore.hasRemotePush else { return }
        let style = UserDefaults.standard.data(forKey: "apex.notificationStyle")
            .flatMap { try? JSONDecoder().decode(NotificationStyle.self, from: $0) } ?? .default
        let events = await RecapBuilder.fetchToday(client: client)
        let recap = RecapBuilder.build(events: events, style: style)
        RecapSettings.markSentToday()

        let content = UNMutableNotificationContent()
        content.title = "🧾 Daily Recap — \(recap.headline)"
        content.body = recap.notificationBody
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "apex-recap-\(RecapSettings.todayKey())",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
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
            password: password
        )
        KeychainStore().save(session: next)
        let defaults = UserDefaults(suiteName: ApexAppGroup.identifier)
        defaults?.set(next.baseURL.absoluteString, forKey: "apex.frigateBaseURL")
        defaults?.set(token, forKey: "apex.frigateToken")
        return next
    }
}
