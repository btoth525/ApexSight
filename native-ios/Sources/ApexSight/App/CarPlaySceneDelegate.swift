import CarPlay
import UIKit

/// CarPlay surface for ApexSight (Driving Task). CarPlay forbids live video while
/// driving, so this shows a glanceable, auto-refreshing feed: recent alerts with
/// thumbnails and a camera list with the latest still. Runs in the app process and
/// pulls fresh data directly from Frigate using the saved session.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var refreshTimer: Timer?

    private let alertsTemplate = CPListTemplate(title: "Alerts", sections: [])
    private let camerasTemplate = CPListTemplate(title: "Cameras", sections: [])

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        alertsTemplate.tabImage = UIImage(systemName: "bell.fill")
        camerasTemplate.tabImage = UIImage(systemName: "video.fill")
        alertsTemplate.updateSections([loadingSection()])
        camerasTemplate.updateSections([loadingSection()])

        let tabBar = CPTabBarTemplate(templates: [alertsTemplate, camerasTemplate])
        interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)

        Task { await refresh() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        self.interfaceController = nil
    }

    // MARK: - Refresh

    @MainActor
    private func refresh() async {
        guard let session = KeychainStore().loadSession() else {
            alertsTemplate.updateSections([messageSection("Sign in on your iPhone")])
            return
        }
        let client = FrigateClient(session: session)

        // Alerts — recent un-reviewed reviews with a thumbnail.
        if let reviews = try? await client.reviews(limit: 12, reviewed: false) {
            var items: [CPListItem] = []
            for review in reviews {
                let subject = review.data?.subLabels?.first ?? review.data?.objects?.first ?? "Activity"
                let item = CPListItem(
                    text: "\(emoji(for: review)) \(titleize(subject))",
                    detailText: "\(titleize(review.camera)) · \(relative(review.startTime))"
                )
                item.handler = { _, completion in completion() }
                items.append(item)
            }
            alertsTemplate.updateSections([
                CPListSection(items: items.isEmpty ? [CPListItem(text: "All clear", detailText: "No recent alerts")] : items)
            ])
            // Fill in thumbnails as they download (CPListItem updates live).
            for (item, review) in zip(items, reviews) {
                if let url = client.reviewThumbnailURL(review: review),
                   let data = try? await client.imageData(from: url),
                   let image = UIImage(data: data) {
                    item.setImage(image)
                }
            }
        }

        // Cameras — latest still for each.
        let names = SharedSnapshotStore.loadCameraNames()
        let camItems = names.map { name -> CPListItem in
            let item = CPListItem(text: titleize(name), detailText: nil)
            item.handler = { _, completion in completion() }
            return item
        }
        camerasTemplate.updateSections([
            CPListSection(items: camItems.isEmpty ? [CPListItem(text: "No cameras", detailText: nil)] : camItems)
        ])
        for (item, name) in zip(camItems, names) {
            if let data = try? await client.imageData(from: client.latestFrameURL(camera: name)),
               let image = UIImage(data: data) {
                item.setImage(image)
            }
        }
    }

    // MARK: - Helpers

    private func loadingSection() -> CPListSection {
        CPListSection(items: [CPListItem(text: "Loading…", detailText: nil)])
    }

    private func messageSection(_ text: String) -> CPListSection {
        CPListSection(items: [CPListItem(text: text, detailText: nil)])
    }

    private func relative(_ epoch: Double?) -> String {
        let date = Date(timeIntervalSince1970: epoch ?? Date().timeIntervalSince1970)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func emoji(for review: FrigateReviewItem) -> String {
        let key = (review.data?.subLabels?.first ?? review.data?.objects?.first ?? "").lowercased()
        switch key {
        case "person": return "🚶"
        case "car", "vehicle": return "🚗"
        case "truck": return "🚚"
        case "dog": return "🐕"
        case "cat": return "🐈"
        case "package", "amazon", "ups", "fedex", "usps": return "📦"
        case "bicycle": return "🚲"
        default: return review.severity == "alert" ? "🚨" : "📹"
        }
    }
}
