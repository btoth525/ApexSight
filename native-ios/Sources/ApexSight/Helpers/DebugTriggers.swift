#if DEBUG
import Foundation

/// DEBUG-only deterministic triggers for surfaces that otherwise need a real Frigate alert:
/// the Live Activity / Dynamic Island path and the Apple Watch push. Callable from the
/// Settings "Developer" card (a tap) or from an `apex://debug?action=…` deep link stashed in
/// the app group and consumed on cold launch (useful when synthetic taps aren't available).
/// The whole file is behind `#if DEBUG`, so none of this ships in Release.
@MainActor
enum DebugTriggers {
    static func fireLiveActivity(camera: String) {
        IncidentActivityController.startOrUpdate(review: review(camera: camera))
    }

    static func fireWatchPush(camera: String) {
        WatchSyncManager.shared.push(alerts: [alert(camera: camera)], heroJPEG: heroJPEG())
    }

    private static func review(camera: String) -> FrigateReviewItem {
        FrigateReviewItem(
            id: "debug-\(UUID().uuidString)",
            camera: camera,
            startTime: Date().timeIntervalSince1970,
            endTime: nil,
            severity: "alert",
            thumbPath: nil,
            hasBeenReviewed: false,
            data: ReviewData(detections: ["person"], objects: ["person"], subLabels: nil, zones: ["front_yard"], audio: nil, thumbTime: nil, verifiedObjects: nil),
            description: "Person detected (debug)"
        )
    }

    private static func alert(camera: String) -> SharedAlert {
        SharedAlert(
            id: "debug-\(UUID().uuidString)",
            label: "person",
            subLabel: nil,
            camera: camera,
            severity: "alert",
            when: Date(),
            imageFileName: nil,
            zone: "front_yard"
        )
    }

    /// Reuse the most recent cached camera snapshot as the watch hero, if one exists.
    private static func heroJPEG() -> Data? {
        guard let (_, url) = SharedSnapshotStore.load() else { return nil }
        return try? Data(contentsOf: url)
    }
}
#endif
