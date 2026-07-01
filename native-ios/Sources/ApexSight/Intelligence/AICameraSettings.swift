import Foundation

/// Per-camera control over on-device AI analysis. Default: every camera is enabled (AI works out
/// of the box); the user turns OFF specific cameras in Settings → Apple Intelligence → AI Cameras.
/// Stored as the DISABLED set so newly-added cameras are enabled by default.
enum AICameraSettings {
    private static let disabledKey = "ai.cameras.disabled"
    // App Group so the Notification Service Extension (a separate process) can honor per-camera AI
    // when it enriches a closed-app push. Falls back to standard defaults if the suite is missing.
    private static var defaults: UserDefaults { UserDefaults(suiteName: ApexAppGroup.identifier) ?? .standard }

    static var disabledCameras: Set<String> {
        get { Set(defaults.stringArray(forKey: disabledKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: disabledKey) }
    }

    /// Whether on-device AI should run for this camera (master AI toggle is checked separately).
    static func isEnabled(_ camera: String) -> Bool { !disabledCameras.contains(camera) }

    static func setEnabled(_ enabled: Bool, for camera: String) {
        var set = disabledCameras
        if enabled { set.remove(camera) } else { set.insert(camera) }
        disabledCameras = set
    }
}
