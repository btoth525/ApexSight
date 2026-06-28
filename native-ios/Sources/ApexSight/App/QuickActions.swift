import UIKit

/// Home Screen quick actions (long-press the app icon). Each maps to an `apex://` link and
/// reuses the existing pendingIntentLink → `AppState.handleDeepLink` pipeline, so the same
/// verbs also work from Control Center, Siri, and notifications. The base actions (Snooze,
/// Latest) are set at launch; a couple of cameras are added once the camera list loads.
enum QuickActions {
    static let snoozeType = "com.brandontoth.apexsight.snooze"
    static let latestType = "com.brandontoth.apexsight.latest"
    static let cameraType = "com.brandontoth.apexsight.camera"

    /// Posted after a tapped shortcut is stashed, so AppState consumes it immediately — a warm
    /// tap (app already launched) doesn't change scenePhase, so we can't rely on that path.
    static let didTrigger = Notification.Name("apex.quickActionTriggered")

    /// Stash the tapped action as a pending deep link and nudge AppState to consume it.
    static func handle(_ item: UIApplicationShortcutItem) {
        let link: String
        switch item.type {
        case snoozeType:
            link = "apex://snooze"
        case latestType:
            link = "apex://latest"
        case cameraType:
            guard let name = item.userInfo?["name"] as? String else { return }
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
            link = "apex://camera?name=\(encoded)"
        default:
            return
        }
        UserDefaults(suiteName: ApexAppGroup.identifier)?.set(link, forKey: "apex.pendingIntentLink")
        NotificationCenter.default.post(name: didTrigger, object: nil)
    }

    /// Always-present actions, set at launch so they show on first long-press.
    static func baseItems() -> [UIApplicationShortcutItem] {
        [
            UIApplicationShortcutItem(
                type: snoozeType,
                localizedTitle: "Snooze Alerts",
                localizedSubtitle: "Silence for 1 hour",
                icon: UIApplicationShortcutIcon(systemImageName: "moon.zzz.fill")
            ),
            UIApplicationShortcutItem(
                type: latestType,
                localizedTitle: "Latest Alert",
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: "bell.fill")
            )
        ]
    }

    /// Refresh the list = base actions + the first couple of cameras (system caps at 4 total).
    @MainActor
    static func update(cameras: [FrigateCamera]) {
        var items = baseItems()
        for camera in cameras.prefix(2) {
            items.append(UIApplicationShortcutItem(
                type: cameraType,
                localizedTitle: titleize(camera.name),
                localizedSubtitle: "Open camera",
                icon: UIApplicationShortcutIcon(systemImageName: "video.fill"),
                userInfo: ["name": camera.name as NSString]
            ))
        }
        UIApplication.shared.shortcutItems = items
    }
}

/// Receives WARM quick-action taps (app already launched) for the main window scene. It
/// deliberately does NOT implement `scene(_:willConnectTo:)` — doing so makes SwiftUI think
/// this delegate owns window setup and its WindowGroup content never attaches (blank screen).
/// Cold-launch shortcuts are captured in `AppDelegate.configurationForConnecting` instead.
final class ApexSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        QuickActions.handle(shortcutItem)
        completionHandler(true)
    }
}
