import Foundation

/// Pure decision logic for whether a camera's activity should surface in the Review/Activity
/// feeds under the current house mode. Extracted out of `AppState.cameraVisibleInFeeds` so it's
/// directly unit-testable without instantiating `AppState` (which starts an `NWPathMonitor` and
/// activates `WatchSyncManager` in `init()` — real side effects a test target shouldn't trigger).
enum HouseModeVisibility {
    /// FAIL-OPEN: hidden only when the current mode affirmatively mutes the camera AND the user
    /// hasn't chosen to show all. Unknown mode / empty mute list / a camera not in the list all
    /// show; a miss only ever fails open (shows the camera), never hides it.
    static func cameraVisible(_ camera: String, mutedCameras: [String], showAll: Bool) -> Bool {
        if showAll { return true }
        guard !camera.isEmpty, !mutedCameras.isEmpty else { return true }
        // Case-insensitive so an intended mute still applies even if the relay ever returns a
        // differently-cased camera name; a miss only ever fails OPEN (shows the camera).
        let key = camera.lowercased()
        return !mutedCameras.contains { $0.lowercased() == key }
    }
}
