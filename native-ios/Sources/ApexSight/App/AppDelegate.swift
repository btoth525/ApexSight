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
        // Show the base Home Screen quick actions from the first long-press; AppState adds
        // per-camera actions once the camera list loads.
        UIApplication.shared.shortcutItems = QuickActions.baseItems()
        return true
    }

    /// Attach a window-scene delegate so Home Screen quick actions are delivered (SwiftUI's
    /// App lifecycle doesn't surface them otherwise). The delegate only forwards shortcuts —
    /// it never builds a window — so SwiftUI's WindowGroup still owns the UI.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowApplication {
            config.delegateClass = ApexSceneDelegate.self
            // Cold launch from a quick action: the tapped shortcut is delivered here (the
            // scene delegate must NOT implement willConnectTo, which would blank SwiftUI), so
            // stash it now for the pendingIntentLink pipeline to consume on launch.
            if let shortcut = options.shortcutItem {
                QuickActions.handle(shortcut)
            }
        }
        return config
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
        //
        // The outcome MUST be recorded: `hasRemotePush` (which suppresses every local
        // fallback path) now requires `relayConfirmed`. Swallowing a failed registration
        // here used to leave the app in "relay will push" mode while the relay had no
        // token — a total, silent notification blackout until the next launch.
        Task {
            let relayURL = DeviceTokenStore.relayURL
            let pairing = DeviceTokenStore.ensurePairingCode()
            guard !relayURL.isEmpty, !pairing.isEmpty else { return }
            for attempt in 0..<2 {
                do {
                    try await RelayClient.register(
                        relayURL: relayURL,
                        deviceToken: hex,
                        pairingCode: pairing,
                        environment: APNSEnvironment.current
                    )
                    DeviceTokenStore.relayConfirmed = true
                    DeviceTokenStore.lastError = nil
                    return
                } catch {
                    DeviceTokenStore.lastError = "Relay registration failed: \(error.localizedDescription)"
                    // One quick retry rides out a transient blip (DNS, tunnel hiccup)
                    // before dropping back to local notifications for this session.
                    if attempt == 0 { try? await Task.sleep(nanoseconds: 10_000_000_000) }
                }
            }
            DeviceTokenStore.relayConfirmed = false
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        DeviceTokenStore.lastError = error.localizedDescription
        // No usable token → the relay can't reach this device; let local paths take over.
        DeviceTokenStore.relayConfirmed = false
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Synchronous, main-actor witness for a @MainActor protocol requirement — UIKit
        // delivers on the main actor, so the non-Sendable userInfo never crosses an
        // isolation boundary (the async variant warns under Swift 6 strict concurrency).
        Task {
            await BackgroundRefreshManager.performRefresh()
            completionHandler(.newData)
        }
    }
}
