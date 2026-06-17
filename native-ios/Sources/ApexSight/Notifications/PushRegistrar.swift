import UIKit
import UserNotifications

/// Registers this device for APNs on every launch/foreground and lets the
/// AppDelegate forward the resulting token to the relay — exactly how mainstream
/// apps keep their push token current (and self-heal token rotation after an
/// update, reinstall, or restore). Push is "always on" for ApexSight, so there's
/// nothing for the user to toggle.
enum PushRegistrar {
    static func ensureRegistered() {
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
            }
            let status = await center.notificationSettings().authorizationStatus
            // Register whenever the user hasn't explicitly denied — this fires
            // didRegisterForRemoteNotificationsWithDeviceToken, which (re)sends the
            // token to the relay.
            guard status != .denied, status != .notDetermined else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }
}
