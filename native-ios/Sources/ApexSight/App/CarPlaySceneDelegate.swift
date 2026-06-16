import CarPlay
import UIKit

/// CarPlay surface for ApexSight (Driving Task). Glanceable + hands-free:
/// • Alerts tab: recent alerts with thumbnails, auto-refreshing every 30s.
/// • Cameras tab: each camera's latest still.
/// • A pop-up the moment a new alert arrives (while ApexSight is the active CarPlay app).
/// • Tap any alert or camera → a detail screen with the snapshot + info.
/// No live video (CarPlay forbids it while driving).
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var refreshTimer: Timer?

    private let alertsTemplate = CPListTemplate(title: "Alerts", sections: [])
    private let camerasTemplate = CPListTemplate(title: "Cameras", sections: [])

    private var lastSeenReviewID: String?
    private var hasLoadedOnce = false

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

        if let reviews = try? await client.reviews(limit: 12, reviewed: false) {
            // Pop a banner for a genuinely new alert (not on first load).
            if let newest = reviews.first {
                if hasLoadedOnce, let last = lastSeenReviewID, newest.id != last {
                    presentNewAlert(newest, client: client)
                }
                lastSeenReviewID = newest.id
            }
            hasLoadedOnce = true

            var items: [CPListItem] = []
            for review in reviews {
                let subject = review.data?.subLabels?.first ?? review.data?.objects?.first ?? "Activity"
                let item = CPListItem(
                    text: "\(emoji(for: review)) \(titleize(subject))",
                    detailText: "\(titleize(review.camera)) · \(relative(review.startTime))"
                )
                item.handler = { [weak self] _, completion in
                    completion()
                    Task { await self?.pushAlertDetail(review, client: client) }
                }
                items.append(item)
            }
            alertsTemplate.updateSections([
                CPListSection(items: items.isEmpty ? [CPListItem(text: "All clear", detailText: "No recent alerts")] : items)
            ])
            for (item, review) in zip(items, reviews) {
                if let url = client.reviewThumbnailURL(review: review),
                   let data = try? await client.imageData(from: url),
                   let image = UIImage(data: data) {
                    item.setImage(image)
                }
            }
        }

        let names = SharedSnapshotStore.loadCameraNames()
        let camItems = names.map { name -> CPListItem in
            let item = CPListItem(text: titleize(name), detailText: "Tap for latest")
            item.handler = { [weak self] _, completion in
                completion()
                Task { await self?.pushCameraDetail(name, client: client) }
            }
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

    // MARK: - New-alert pop-up

    @MainActor
    private func presentNewAlert(_ review: FrigateReviewItem, client: FrigateClient) {
        let subject = review.data?.subLabels?.first ?? review.data?.objects?.first ?? "Activity"
        let full = "\(emoji(for: review)) \(titleize(subject)) · \(titleize(review.camera))"
        let short = "\(emoji(for: review)) \(titleize(subject))"

        let view = CPAlertAction(title: "View", style: .default) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
            Task { await self?.pushAlertDetail(review, client: client) }
        }
        let dismiss = CPAlertAction(title: "Dismiss", style: .cancel) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
        }
        let alert = CPAlertTemplate(titleVariants: [full, short], actions: [view, dismiss])
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
    }

    // MARK: - Detail screens (snapshot + info)

    @MainActor
    private func pushAlertDetail(_ review: FrigateReviewItem, client: FrigateClient) async {
        let subject = review.data?.subLabels?.first ?? review.data?.objects?.first ?? "Activity"
        let hero = CPListItem(text: titleize(subject), detailText: relative(review.startTime))
        var rows: [CPListItem] = [hero]
        rows.append(CPListItem(text: "Camera", detailText: titleize(review.camera)))
        if let zones = review.data?.zones, !zones.isEmpty {
            rows.append(CPListItem(text: "Zone", detailText: zones.map(titleize).joined(separator: ", ")))
        }
        let detail = CPListTemplate(title: titleize(review.camera), sections: [CPListSection(items: rows)])
        interfaceController?.pushTemplate(detail, animated: true, completion: nil)

        if let url = client.reviewSnapshotURL(review: review) ?? client.reviewThumbnailURL(review: review),
           let data = try? await client.imageData(from: url),
           let image = UIImage(data: data) {
            hero.setImage(downscaled(image))
        }
    }

    @MainActor
    private func pushCameraDetail(_ name: String, client: FrigateClient) async {
        let hero = CPListItem(text: titleize(name), detailText: "Latest still")
        let detail = CPListTemplate(title: titleize(name), sections: [CPListSection(items: [hero])])
        interfaceController?.pushTemplate(detail, animated: true, completion: nil)

        if let data = try? await client.imageData(from: client.latestFrameURL(camera: name)),
           let image = UIImage(data: data) {
            hero.setImage(downscaled(image))
        }
    }

    // MARK: - Helpers

    private func loadingSection() -> CPListSection {
        CPListSection(items: [CPListItem(text: "Loading…", detailText: nil)])
    }

    private func messageSection(_ text: String) -> CPListSection {
        CPListSection(items: [CPListItem(text: text, detailText: nil)])
    }

    /// CarPlay caps image sizes; keep snapshots modest so they render crisply.
    private func downscaled(_ image: UIImage, maxDimension: CGFloat = 480) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: newSize).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
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
