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

        // Restore the existing activity from a previous app session if we lost our handle.
        if current == nil {
            current = Activity<IncidentActivityAttributes>.activities.first
        }
        // Drop a stale handle (e.g. the user tapped "Dismiss") so a new alert starts fresh.
        if let existing = current, existing.activityState != .active {
            current = nil
        }

        if let current {
            Task { await current.update(ActivityContent(state: state, staleDate: nil)) }
        } else {
            let attributes = IncidentActivityAttributes(
                camera: review.camera,
                startedAt: Date(timeIntervalSince1970: review.startTime ?? Date().timeIntervalSince1970)
            )
            current = try? Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(300)),
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
