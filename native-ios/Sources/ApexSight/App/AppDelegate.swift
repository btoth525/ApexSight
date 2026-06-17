import UIKit

/// SwiftUI's App lifecycle can't receive APNs callbacks directly, so this adaptor
/// captures the device token for the optional push companion and registers the
/// background refresh task. Remote-notification registration is NOT triggered here —
/// it's gated behind the Settings toggle so the app is fully functional without APNs.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundRefreshManager.register()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        DeviceTokenStore.deviceTokenHex = hex
        DeviceTokenStore.pushEnabled = true
        DeviceTokenStore.lastError = nil
        // Re-send the token to the relay on EVERY registration (every launch/foreground),
        // so the relay always holds the current token — like other apps. This self-heals
        // a rotated token after an app update, reinstall, or restore.
        Task {
            let relayURL = DeviceTokenStore.relayURL
            let pairing = DeviceTokenStore.ensurePairingCode()
            guard !relayURL.isEmpty, !pairing.isEmpty else { return }
            try? await RelayClient.register(
                relayURL: relayURL,
                deviceToken: hex,
                pairingCode: pairing,
                environment: APNSEnvironment.current
            )
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        DeviceTokenStore.lastError = error.localizedDescription
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        await BackgroundRefreshManager.performRefresh()
        return .newData
    }
}
