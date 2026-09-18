import Combine
import Foundation

/// The small slice of `AppState` that the camera wall and image views actually need, on an object
/// that republishes ONLY when one of those values truly changes.
///
/// `@EnvironmentObject AppState` invalidates a view on ANY `objectWillChange`. During a person event
/// AppState publishes ~7 Hz of live detections plus ~4 Hz of events, so every thumbnail AND every
/// live camera tile on the wall re-evaluated `body` a dozen times a second for values that never
/// moved (the client, the camera capabilities, the HLS verdict). This object watches AppState on
/// their behalf and forwards each field only when it changes, so motion-driven feed churn no longer
/// re-renders the wall. `RemoteImage`/`TrackedSnapshot` (client only) and the live tiles
/// (`LiveCameraTile`/`HLSLivePlayerView`) all observe this instead of AppState.
@MainActor
final class ImageSession: ObservableObject {
    static let shared = ImageSession()

    @Published private(set) var client: FrigateClient?
    // Wall inputs — all rarely-changing, so publishing only on change keeps the wall still during
    // feed churn.
    @Published private(set) var liveHLSAvailable = true
    @Published private(set) var onLocalNetwork = false
    @Published private(set) var subStreamsKnown = false
    @Published private(set) var subStreamCameras: Set<String> = []
    @Published private(set) var hasBirdseye = false
    /// Keyed by camera name for O(1) lookup (the wall previously did a linear `first(where:)` per
    /// tile per render).
    @Published private(set) var capabilities: [String: CameraCapability] = [:]

    private weak var appState: AppState?
    private var subscription: AnyCancellable?

    private init() {}

    func bind(_ appState: AppState) {
        self.appState = appState
        client = appState.client
        syncWallInputs(from: appState)
        subscription = appState.objectWillChange
            // Hop to the next tick so we read the NEW values (objectWillChange fires *before* the
            // assignment). Each field is guarded by `!=`, so a churn tick that changed none of our
            // values publishes nothing.
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak appState] _ in
                guard let self, let appState else { return }
                let next = appState.client
                if next?.identity != self.client?.identity { self.client = next }
                self.syncWallInputs(from: appState)
            }
    }

    private func syncWallInputs(from appState: AppState) {
        if liveHLSAvailable != appState.liveHLSAvailable { liveHLSAvailable = appState.liveHLSAvailable }
        if onLocalNetwork != appState.onLocalNetwork { onLocalNetwork = appState.onLocalNetwork }
        if subStreamsKnown != appState.subStreamsKnown { subStreamsKnown = appState.subStreamsKnown }
        if subStreamCameras != appState.subStreamCameras { subStreamCameras = appState.subStreamCameras }
        if hasBirdseye != appState.hasBirdseye { hasBirdseye = appState.hasBirdseye }
        let dict = Dictionary(appState.capabilities.map { ($0.camera, $0) }, uniquingKeysWith: { a, _ in a })
        if dict != capabilities { capabilities = dict }
    }

    /// Re-run login on a 401 — forwarded so image loaders keep their existing recovery path.
    func reauthenticate() async -> Bool {
        await appState?.reauthenticate() ?? false
    }
}
