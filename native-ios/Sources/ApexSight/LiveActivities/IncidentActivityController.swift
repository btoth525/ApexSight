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

        // Single-banner policy: retire EVERY live incident banner that isn't this camera's —
        // not just the one we hold a handle to. Orphans happen when the handle is lost across
        // an app session or a relay push started one remotely; ending only `current` left
        // those stacked on the Lock Screen next to the new banner.
        for stale in Activity<IncidentActivityAttributes>.activities
        where stale.activityState == .active && stale.attributes.camera != review.camera {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }

        // Reconnect to our own activity if we lost the handle — but ONLY one for THIS camera.
        // The camera lives in the immutable attributes and can't be updated in place, so
        // adopting a different camera's banner would show this alert's text while its
        // "View Live" link and tap target still point at the wrong camera.
        if current?.activityState != .active || current?.attributes.camera != review.camera {
            current = Activity<IncidentActivityAttributes>.activities.first {
                $0.activityState == .active && $0.attributes.camera == review.camera
            }
        }

        // Backstop: if the app is suspended before the 45s auto-end fires (Task.sleep doesn't
        // advance while suspended), this lets WidgetKit mark the activity stale so it dims and
        // the system reclaims it, instead of lingering frozen-fresh on the Lock Screen.
        let staleDate = Date().addingTimeInterval(300)

        if let current {
            Task { await current.update(ActivityContent(state: state, staleDate: staleDate)) }
        } else {
            let attributes = IncidentActivityAttributes(
                camera: review.camera,
                startedAt: review.startTime ?? Date().timeIntervalSince1970
            )
            current = try? Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: staleDate),
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

    /// End only one camera's incident banner — for the review-`.end` path, where camera
    /// A's review finishing must not tear down camera B's still-active incident (or a
    /// relay-push-started banner for another camera). The end-everything `end()` stays
    /// for explicit dismissal / app-open.
    static func end(camera: String) {
        if current?.attributes.camera == camera {
            endTask?.cancel()
            endTask = nil
            current = nil
        }
        Task {
            for activity in Activity<IncidentActivityAttributes>.activities
            where activity.attributes.camera == camera {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private static func scheduleAutoEnd() {
        endTask?.cancel()
        // Capture the activity this timer owns, so a stale 45s timer ends only the banner it was
        // scheduled for — never a different camera's banner or one the relay push-started later.
        let target = current
        endTask = Task {
            try? await Task.sleep(nanoseconds: 45_000_000_000) // 45s — don't linger
            // Re-verify at the last synchronous moment: a fresh alert may have updated the
            // banner and rescheduled while this timer's sleep was completing — its cancel
            // only helps if we check again here, and `target` must still be the banner the
            // controller considers live.
            guard !Task.isCancelled, let target, target.id == current?.id else { return }
            await target.end(nil, dismissalPolicy: .immediate)
            if current?.id == target.id { current = nil }
        }
    }
}
