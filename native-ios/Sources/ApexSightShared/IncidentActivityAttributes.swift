import ActivityKit
import Foundation

/// Shared between the app (which starts/updates the Activity) and the widget
/// extension (which renders the Lock Screen / Dynamic Island UI).
struct IncidentActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var detail: String
        var severity: String
        /// App-group-relative filename of the cached detection snapshot. Live Activities
        /// can only render local files (never remote URLs), so the app downloads the
        /// snapshot into the shared container and passes the filename here; the widget
        /// resolves it back to a file URL via `SharedSnapshotStore.incidentSnapshotURL`.
        /// Optional + filled in a moment after the banner appears, so the text shows
        /// instantly and the image streams in.
        var snapshotName: String?
    }

    var camera: String
    var startedAt: Date
}
