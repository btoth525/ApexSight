import ActivityKit
import Foundation

/// Starts, updates, and ends a Live Activity for an in-progress alert incident.
/// Driven from AppState when a new alert-severity review arrives over the stream.
@MainActor
enum IncidentActivityController {
    private static var current: Activity<IncidentActivityAttributes>?
    private static var endTask: Task<Void, Never>?
    /// The cached snapshot filename for the active incident, so updates keep showing the
    /// image and we only download it once per incident.
    private static var snapshotName: String?

    static func startOrUpdate(review: FrigateReviewItem, client: FrigateClient?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // Restore the existing activity from a previous app session if we lost our handle.
        if current == nil {
            current = Activity<IncidentActivityAttributes>.activities.first
        }
        // Drop a stale handle (e.g. the user tapped "Dismiss") so a new alert starts fresh.
        if let existing = current, existing.activityState != .active {
            current = nil
            snapshotName = nil
        }

        let isNewIncident = (current == nil)

        let state = IncidentActivityAttributes.ContentState(
            title: NotificationCopy.title(for: review),
            detail: NotificationCopy.body(for: review),
            severity: review.severity ?? "alert",
            // Carry forward any image already cached for this incident so an update
            // (more objects detected) doesn't drop the snapshot.
            snapshotName: snapshotName
        )

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

        // Show the text banner instantly, then download the detection snapshot and patch
        // it into the live activity a moment later — best-of-both: immediate + visual.
        if isNewIncident, snapshotName == nil, let client {
            fetchAndAttachSnapshot(review: review, client: client)
        }

        scheduleAutoEnd()
    }

    /// Downloads the incident's detection snapshot, writes it to the shared container, and
    /// updates the running activity's ContentState so the image appears in the Dynamic
    /// Island / Lock Screen. Runs on the main actor (only `await`s, never blocks).
    private static func fetchAndAttachSnapshot(review: FrigateReviewItem, client: FrigateClient) {
        Task {
            // The WebSocket review payload often arrives before detections are processed,
            // so reviewSnapshotURL would return nil. Fetch the full review to get a
            // detection id we can resolve a snapshot/thumbnail URL from.
            let full: FrigateReviewItem
            if review.data?.detections?.isEmpty != false {
                full = (try? await client.review(id: review.id)) ?? review
            } else {
                full = review
            }

            guard
                let url = client.reviewSnapshotURL(review: full) ?? client.reviewThumbnailURL(review: full),
                let data = try? await client.imageData(from: url),
                let name = SharedSnapshotStore.saveIncidentSnapshot(data, token: sanitizedToken(review.id))
            else { return }

            snapshotName = name
            // Only patch a still-active incident; otherwise we'd resurrect a dismissed one.
            guard let active = current, active.activityState == .active else { return }
            var next = active.content.state
            next.snapshotName = name
            await active.update(ActivityContent(state: next, staleDate: nil))
        }
    }

    static func end() {
        endTask?.cancel()
        endTask = nil
        current = nil
        snapshotName = nil
        // End every incident activity (current + any restored from a prior session) so
        // opening the app / tapping Dismiss reliably clears it.
        Task {
            for activity in Activity<IncidentActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        SharedSnapshotStore.clearIncidentSnapshots()
    }

    private static func scheduleAutoEnd() {
        endTask?.cancel()
        endTask = Task {
            try? await Task.sleep(nanoseconds: 45_000_000_000) // 45s — don't linger
            guard !Task.isCancelled else { return }
            end()
        }
    }

    /// Filename-safe token from a Frigate review id (keeps unique-per-incident URLs).
    private static func sanitizedToken(_ id: String) -> String {
        let allowed = id.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        return String(allowed)
    }
}
