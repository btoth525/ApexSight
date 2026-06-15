import CarPlay
import UIKit

/// CarPlay surface for ApexSight. CarPlay forbids live video for driver safety, so
/// this shows the recent-alerts feed and a camera list using still snapshots from
/// the app group (the same feed the widget and Watch use). Runs in the iOS app
/// process, so it reads shared storage directly.
///
/// NOTE: CarPlay also requires a CarPlay entitlement granted by Apple for your App
/// ID before the scene will connect on a real head unit / the CarPlay Simulator.
/// Request it at developer.apple.com, then add the granted key to the app's
/// entitlements. Until then this code is inert — it does not affect the iOS app.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        let tabBar = CPTabBarTemplate(templates: [recentAlertsTemplate(), camerasTemplate()])
        interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }

    // MARK: - Templates

    private func recentAlertsTemplate() -> CPListTemplate {
        let (alerts, heroURL) = SharedSnapshotStore.loadRecentAlerts()
        let items: [CPListItem] = alerts.map { alert in
            let title = displayName(alert.subLabel ?? alert.label)
            let detail = "\(displayName(alert.camera)) · \(relative(alert.when))"
            let item = CPListItem(text: title, detailText: detail)
            // Only a still image is allowed in CarPlay — attach the latest snapshot.
            if alert.id == alerts.first?.id, let heroURL, let image = UIImage(contentsOfFile: heroURL.path) {
                item.setImage(image)
            }
            return item
        }
        let section = CPListSection(items: items.isEmpty
            ? [CPListItem(text: "No recent alerts", detailText: nil)]
            : items)
        let template = CPListTemplate(title: "Alerts", sections: [section])
        template.tabImage = UIImage(systemName: "bell.fill")
        return template
    }

    private func camerasTemplate() -> CPListTemplate {
        let names = SharedSnapshotStore.loadCameraNames()
        let items = names.map { CPListItem(text: displayName($0), detailText: nil) }
        let section = CPListSection(items: items.isEmpty
            ? [CPListItem(text: "No cameras", detailText: nil)]
            : items)
        let template = CPListTemplate(title: "Cameras", sections: [section])
        template.tabImage = UIImage(systemName: "video.fill")
        return template
    }

    // MARK: - Helpers

    private func displayName(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
