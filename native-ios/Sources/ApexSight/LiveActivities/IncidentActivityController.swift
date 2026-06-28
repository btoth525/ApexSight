import ActivityKit
import Foundation

/// Starts, updates, and ends a Live Activity for an in-progress alert incident.
/// Driven from AppState when a new alert-severity review arrives over the stream.
@MainActor
enum IncidentActivityController {
    private static var current: Activity<IncidentActivityAttributes>?
    private static var endTask: Task<Void, Never>?

    static func startOrUpdate(review: FrigateReviewItem) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let state = IncidentActivityAttributes.ContentState(
            title: NotificationCopy.title(for: review),
            detail: NotificationCopy.body(for: review),
            severity: review.severity ?? "alert"
        )

        // Adopt any live activity already on screen — whether we lost our handle across an app
        // session OR the relay push-started one for this same incident — so we update it in place
        // instead of stacking a second banner for the same event.
        if current == nil || current?.activityState != .active {
            current = Activity<IncidentActivityAttributes>.activities.first { $0.activityState == .active }
        }

        if let current {
            Task { await current.update(ActivityContent(state: state, staleDate: nil)) }
        } else {
            let attributes = IncidentActivityAttributes(
                camera: review.camera,
                startedAt: review.startTime ?? Date().timeIntervalSince1970
            )
            // No staleDate: this locally-started activity is owned by our 45s auto-end timer
            // below, so a stale window would be dead code (it never outlives the timer).
            current = try? Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        }

        scheduleAutoEnd()
    }

    static func end() {
        endTask?.cancel()
        endTask = nil
        current = nil
        // End every incident activity (current + any restored from a prior session) so
        // opening the app / tapping Dismiss reliably clears it.
        Task {
            for activity in Activity<IncidentActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private static func scheduleAutoEnd() {
        endTask?.cancel()
        endTask = Task {
            try? await Task.sleep(nanoseconds: 45_000_000_000) // 45s — don't linger
            guard !Task.isCancelled else { return }
            end()
        }
    }
}
