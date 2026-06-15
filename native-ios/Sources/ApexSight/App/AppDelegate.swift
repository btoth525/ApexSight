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
        DeviceTokenStore.deviceTokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
        DeviceTokenStore.lastError = nil
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
