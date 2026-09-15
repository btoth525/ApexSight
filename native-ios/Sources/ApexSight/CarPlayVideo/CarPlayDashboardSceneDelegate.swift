import CarPlay
import UIKit

/// CarPlay Dashboard tile (navigation entitlement only — CarPlay never creates this scene for a
/// driving-task app). Shows the current feed in the map slot with one shortcut to resume it.
final class CarPlayDashboardSceneDelegate: UIResponder, CPTemplateApplicationDashboardSceneDelegate {
    private var window: UIWindow?
    private let videoVC = CarVideoViewController()

    func templateApplicationDashboardScene(
        _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
        didConnect dashboardController: CPDashboardController,
        to window: UIWindow
    ) {
        self.window = window
        window.rootViewController = videoVC
        window.makeKeyAndVisible()
        if let image = UIImage(systemName: "play.rectangle.fill") {
            dashboardController.shortcutButtons = [
                CPDashboardButton(titleVariants: ["Feed"], subtitleVariants: ["Resume"], image: image) { _ in
                    Task { @MainActor in CarVideoSession.shared.playLast() }
                }
            ]
        }
        Task { @MainActor in
            if CarVideoSession.shared.source == .none { CarVideoSession.shared.playLast() }
        }
    }

    func templateApplicationDashboardScene(
        _ templateApplicationDashboardScene: CPTemplateApplicationDashboardScene,
        didDisconnect dashboardController: CPDashboardController,
        from window: UIWindow
    ) {
        self.window = nil
    }
}
