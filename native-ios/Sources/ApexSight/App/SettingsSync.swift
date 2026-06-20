import Foundation

/// Mirrors a few UI preferences to iCloud key-value storage so they follow you across
/// your devices — no account needed.
///
/// Loop-safe by design: it **pulls** on launch and whenever another device changes a
/// value, and **pushes** only when the app backgrounds — so a cloud update never kicks
/// off a local-change push (and vice-versa). It is completely inert and crash-free until
/// the iCloud "Key-Value storage" capability is enabled on the App ID, so shipping it
/// changes nothing about the build; flipping that one capability turns it on.
enum SettingsSync {
    /// Plain, device-agnostic preferences worth carrying across devices. (Camera
    /// layouts/groups are intentionally left per-device.)
    private static let keys = [
        "colorSchemePreference",
        "review.selectedSeverity",
        "review.sortNewest",
        "activity.sortNewest",
        "biometricLockEnabled",
    ]

    private static let cloud = NSUbiquitousKeyValueStore.default
    private static let local = UserDefaults.standard
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { _ in pullFromCloud() }
        cloud.synchronize()
        pullFromCloud()
    }

    /// iCloud → local. Runs on launch and when another device updates a value.
    static func pullFromCloud() {
        for key in keys {
            if let value = cloud.object(forKey: key) {
                local.set(value, forKey: key)
            }
        }
    }

    /// local → iCloud. Call when the app backgrounds.
    static func pushToCloud() {
        for key in keys {
            if let value = local.object(forKey: key) {
                cloud.set(value, forKey: key)
            }
        }
        cloud.synchronize()
    }
}
