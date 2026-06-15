import BackgroundTasks
import Foundation

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
        guard let session = KeychainStore().loadSession() else { return }
        let client = FrigateClient(session: session)
        guard let reviews = try? await client.reviews(limit: 20) else { return }

        let prefs = await NotificationPreferencesStore()

        for review in reviews where review.severity == "alert" {
            guard LastSeenStore.isNew(review.id) else { continue }
            // Mark seen immediately so a mid-task cancellation can't re-deliver on the next run.
            LastSeenStore.markSeen([review.id])

            let label = review.data?.objects?.first ?? "object"
            let zones = review.data?.zones ?? []
            guard await prefs.shouldDeliver(camera: review.camera, label: label, zones: zones) else { continue }

            await LocalAlertNotifier.notify(review: review, client: client, session: session)
        }
    }
}
