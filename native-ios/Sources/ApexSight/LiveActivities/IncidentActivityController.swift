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

        // Reconnect to our own activity if we lost the handle across an app session — but ONLY
        // one for THIS camera. The camera lives in the immutable attributes and can't be updated
        // in place, so adopting a different camera's banner would show this alert's text while
        // its "View Live" link and tap target still point at the wrong camera.
        if current?.activityState != .active {
            current = Activity<IncidentActivityAttributes>.activities.first {
                $0.activityState == .active && $0.attributes.camera == review.camera
            }
        }

        // Backstop: if the app is suspended before the 45s auto-end fires (Task.sleep doesn't
        // advance while suspended), this lets WidgetKit mark the activity stale so it dims and
        // the system reclaims it, instead of lingering frozen-fresh on the Lock Screen.
        let staleDate = Date().addingTimeInterval(300)

        if let current, current.attributes.camera == review.camera {
            Task { await current.update(ActivityContent(state: state, staleDate: staleDate)) }
        } else {
            // A different camera (or nothing) is showing — retire that activity and start a
            // fresh one whose attributes.camera matches what we display.
            if let stale = current {
                Task { await stale.end(nil, dismissalPolicy: .immediate) }
            }
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

    private static func scheduleAutoEnd() {
        endTask?.cancel()
        // Capture the activity this timer owns, so a stale 45s timer ends only the banner it was
        // scheduled for — never a different camera's banner or one the relay push-started later.
        let target = current
        endTask = Task {
            try? await Task.sleep(nanoseconds: 45_000_000_000) // 45s — don't linger
            guard !Task.isCancelled, let target else { return }
            await target.end(nil, dismissalPolicy: .immediate)
            if current?.id == target.id { current = nil }
        }
    }
}
