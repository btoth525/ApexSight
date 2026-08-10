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
    private var isRefreshing = false

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

        Task { [weak self] in await self?.refresh() }
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
        // A slow/remote link can make one refresh (sequential thumbnail downloads) outlast the
        // 30s timer, so guard against overlapping runs that would double-fire the new-alert
        // pop-up and race lastSeenReviewID.
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        guard let session = KeychainStore().loadSession() else {
            // Not signed in — make BOTH tabs say so, otherwise Cameras stays stuck on
            // the "Loading…" placeholder forever.
            alertsTemplate.updateSections([messageSection("Sign in on your iPhone")])
            camerasTemplate.updateSections([messageSection("Sign in on your iPhone")])
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
                // Cached per review, so the list doesn't pay a round-trip per row after the first.
                if let url = await ReviewStillResolver.shared.pinnedStill(for: review, client: client)
                    ?? client.reviewThumbnailURL(review: review),
                   let data = try? await client.imageData(from: url),
                   let image = UIImage(data: data) {
                    item.setImage(image)
                }
            }
        } else {
            // Signed in but Frigate unreachable — don't leave the Alerts tab stuck on "Loading…"
            // forever (the Cameras tab recovers on its own from the shared snapshot store).
            alertsTemplate.updateSections([messageSection("Can't reach Frigate")])
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
        // CarPlay allows ONE presented template — a newer alert arriving while an older
        // popup is still up was silently dropped. Replace the stale popup with the new one.
        if interfaceController?.presentedTemplate != nil {
            interfaceController?.dismissTemplate(animated: false) { [weak self] _, _ in
                self?.interfaceController?.presentTemplate(alert, animated: true, completion: nil)
            }
        } else {
            interfaceController?.presentTemplate(alert, animated: true, completion: nil)
        }
    }

    // MARK: - Detail screens (snapshot + info)

    @MainActor
    private func pushAlertDetail(_ review: FrigateReviewItem, client: FrigateClient) async {
        let subject = review.data?.subLabels?.first ?? review.data?.objects?.first ?? "Activity"
        var infoRows: [CPListItem] = [CPListItem(text: "Camera", detailText: titleize(review.camera))]
        if let zones = review.data?.zones, !zones.isEmpty {
            infoRows.append(CPListItem(text: "Zone", detailText: zones.map(titleize).joined(separator: ", ")))
        }
        infoRows.append(CPListItem(text: "When", detailText: relative(review.startTime)))

        let detail = CPListTemplate(title: titleize(subject), sections: [
            CPListSection(items: [CPListItem(text: "Loading snapshot…", detailText: nil)]),
            CPListSection(items: infoRows)
        ])
        interfaceController?.pushTemplate(detail, animated: true, completion: nil)

        // Pinned into the review's own window when the object's frame belongs elsewhere — see
        // ReviewStillPolicy. A wrong-moment image matters more here than in the app: on CarPlay the
        // picture is most of what you get, and it is glanced at while driving.
        let url = await ReviewStillResolver.shared.pinnedStill(for: review, client: client)
            ?? client.reviewSnapshotURL(review: review)
            ?? client.reviewThumbnailURL(review: review)
        let imageSection = await snapshotSection(url: url, client: client, label: titleize(review.camera))
            ?? CPListSection(items: [CPListItem(text: "Snapshot unavailable", detailText: nil)])
        detail.updateSections([imageSection, CPListSection(items: infoRows)])
    }

    @MainActor
    private func pushCameraDetail(_ name: String, client: FrigateClient) async {
        let detail = CPListTemplate(title: titleize(name), sections: [
            CPListSection(items: [CPListItem(text: "Loading latest still…", detailText: nil)])
        ])
        interfaceController?.pushTemplate(detail, animated: true, completion: nil)

        let url = client.latestFrameURL(camera: name)
        if let section = await snapshotSection(url: url, client: client, label: titleize(name)) {
            detail.updateSections([section])
        } else {
            detail.updateSections([CPListSection(items: [CPListItem(text: "Still unavailable", detailText: nil)])])
        }
    }

    /// The biggest snapshot CarPlay allows a list app to show: a `CPListImageRowItem` gallery
    /// tile (far larger than a list thumbnail). CarPlay has NO full-screen image template for
    /// camera apps — that's an Apple driver-distraction restriction, not a missing feature. The
    /// snapshot is letterboxed into the row's square so a wide camera isn't cropped.
    @MainActor
    private func snapshotSection(url: URL?, client: FrigateClient, label: String) async -> CPListSection? {
        guard let url,
              let data = try? await client.imageData(from: url),
              let image = UIImage(data: data) else { return nil }
        let tile = squarePadded(downscaled(image, maxDimension: 600))
        let row = CPListImageRowItem(text: label, images: [tile])
        row.listImageRowHandler = { _, _, completion in completion() }
        return CPListSection(items: [row])
    }

    /// Letterbox an image onto a black square so it fills a CarPlay image-row tile without cropping.
    private func squarePadded(_ image: UIImage) -> UIImage {
        let side = max(image.size.width, image.size.height)
        let canvas = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: canvas).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: canvas))
            let origin = CGPoint(x: (side - image.size.width) / 2, y: (side - image.size.height) / 2)
            image.draw(in: CGRect(origin: origin, size: image.size))
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
