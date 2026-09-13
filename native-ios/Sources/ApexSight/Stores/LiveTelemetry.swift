import Foundation

/// The high-frequency live feed — WebSocket detections (republished ~7 Hz during motion) and per-camera
/// control states — on its own observable so only the two views that draw it re-render for it.
/// Living on `AppState`, every publish re-ran `body` for every view observing AppState (Settings,
/// Search, the tab bar, every list…). `AppState` keeps forwarding accessors so its own code is unchanged.
@MainActor
final class LiveTelemetry: ObservableObject {
    static let shared = LiveTelemetry()
    @Published var liveDetections: [String: [LiveDetection]] = [:]
    @Published var cameraControlStates: [String: CameraControlState] = [:]
    /// Frigate's periodic stats frame. Read only by the Health screen.
    @Published var stats: FrigateStats?
    private init() {}
}
