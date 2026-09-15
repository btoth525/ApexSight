import CarPlay
import UIKit

/// CarPlay surface for ApexSight. Two modes, chosen by CarPlay itself from the app's entitlement:
///
/// **Window mode** (`carplay-maps`): CarPlay hands over a full-screen `CPWindow`. The window's root
/// is `CarVideoViewController` — the live feed or the phone-screen mirror, edge to edge — and a
/// transparent `CPMapTemplate` carries the controls (feed picker, mirror, fill, alerts, reconnect).
///
/// **Template mode** (`carplay-driving-task`, what the app ships with today): only templates are
/// allowed, so the car gets tabs — Alerts (auto-refreshing, pop-up on a new one), Cameras and
/// Feeds — and a detail screen whose picture refreshes about once a second ("near-live"): the most
/// motion CarPlay permits without the navigation entitlement.
///
/// Both delegate callbacks are implemented; CarPlay calls exactly one of them per connection.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var refreshTimer: Timer?

    private let alertsTemplate = CPListTemplate(title: "Alerts", sections: [])
    private let camerasTemplate = CPListTemplate(title: "Cameras", sections: [])
    private let feedsTemplate = CPListTemplate(title: "Feeds", sections: [])

    private var lastSeenReviewID: String?
    private var hasLoadedOnce = false
    private var isRefreshing = false

    // Window mode
    private var window: CPWindow?
    private lazy var videoVC = CarVideoViewController()

    // Near-live (template mode)
    private var liveTemplate: CPListTemplate?
    private var liveTask: Task<Void, Never>?
    private var liveTitle = ""

    // MARK: - Template mode (driving-task)

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        interfaceController.delegate = self
        alertsTemplate.tabImage = UIImage(systemName: "bell.fill")
        camerasTemplate.tabImage = UIImage(systemName: "video.fill")
        feedsTemplate.tabImage = UIImage(systemName: "play.rectangle.fill")
        alertsTemplate.updateSections([loadingSection()])
        camerasTemplate.updateSections([loadingSection()])
        rebuildFeedsTab()

        let tabBar = CPTabBarTemplate(templates: [alertsTemplate, camerasTemplate, feedsTemplate])
        interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)
        startRefreshing()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        disconnect()
    }

    // MARK: - Window mode (navigation entitlement)

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        self.interfaceController = interfaceController
        self.window = window
        interfaceController.delegate = self
        window.rootViewController = videoVC
        window.isUserInteractionEnabled = true
        window.makeKeyAndVisible()

        let map = CPMapTemplate()
        map.mapDelegate = self
        map.automaticallyHidesNavigationBar = true
        map.hidesButtonsWithNavigationBar = false
        map.mapButtons = [
            mapButton("list.bullet", label: "Feeds") { [weak self] in self?.showFeedPicker() },
            mapButton("iphone", label: "Mirror") { Task { @MainActor in CarVideoSession.shared.startMirror() } },
            mapButton("arrow.up.left.and.arrow.down.right", label: "Fill") { [weak self] in self?.videoVC.toggleFill() },
            mapButton("bell.fill", label: "Alerts") { [weak self] in
                guard let self else { return }
                self.interfaceController?.pushTemplate(self.alertsTemplate, animated: true, completion: nil)
            }
        ]
        map.trailingNavigationBarButtons = [
            CPBarButton(title: "Reconnect") { _ in Task { @MainActor in CarVideoSession.shared.restart() } }
        ]
        alertsTemplate.updateSections([loadingSection()])
        interfaceController.setRootTemplate(map, animated: false, completion: nil)
        startRefreshing()
        Task { @MainActor in CarVideoSession.shared.playLast() }   // resume the last feed on connect
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        self.window = nil
        disconnect()
    }

    private func disconnect() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        stopLive()
        interfaceController = nil
    }

    private func startRefreshing() {
        Task { [weak self] in await self?.refresh() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    /// Window mode: feeds as a list pushed over the video (allowed for navigation apps).
    private func showFeedPicker() {
        let feeds = FeedStore.shared.feeds
        let items = feeds.map { feed -> CPListItem in
            let item = CPListItem(text: feed.name, detailText: feed.kind.title)
            item.handler = { [weak self] _, completion in
                Task { @MainActor in CarVideoSession.shared.play(feed) }
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
                completion()
            }
            return item
        }
        let list = CPListTemplate(title: "Feeds", sections: [
            CPListSection(items: items.isEmpty ? [CPListItem(text: "No feeds", detailText: "Add them in Settings › Video Feeds")] : items)
        ])
        interfaceController?.pushTemplate(list, animated: true, completion: nil)
    }

    private func mapButton(_ symbol: String, label: String, _ action: @escaping () -> Void) -> CPMapButton {
        let button = CPMapButton { _ in action() }
        let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
        button.image = image
        button.focusedImage = image
        button.accessibilityLabel = label
        return button
    }

    // MARK: - Refresh (both modes)

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
                // The list thumbnail is the review's STATIC thumbnail (tiny, cacheable), decoded
                // at row size and kept per review id. The pinned recording frame is an ffmpeg
                // extraction on the NVR — every 30 s tick used to spawn one per row and decode the
                // full frame; the pinned frame now belongs to the detail screen only.
                if let cached = rowImages[review.id] { item.setImage(cached); continue }
                if let url = client.reviewThumbnailURL(review: review),
                   let data = try? await client.imageData(from: url),
                   let image = RemoteImage.downsample(data, maxPixel: Self.rowImagePixels) {
                    rowImages[review.id] = image
                    if rowImages.count > 40 { rowImages.removeAll() }
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
            let item = CPListItem(text: titleize(name), detailText: "Tap for live view")
            item.handler = { [weak self] _, completion in
                completion()
                self?.pushCameraLive(name, client: client)
            }
            return item
        }
        camerasTemplate.updateSections([
            CPListSection(items: camItems.isEmpty ? [CPListItem(text: "No cameras", detailText: nil)] : camItems)
        ])
        for (item, name) in zip(camItems, names) {
            // Frigate resizes on the server (`height=`) — a row thumbnail, not a full-res frame
            // decoded to ~33 MB per camera and retained by the CPListItem while driving.
            if let url = Self.sizedFrameURL(client.latestFrameURL(camera: name), height: 180),
               let data = try? await client.imageData(from: url),
               let image = RemoteImage.downsample(data, maxPixel: Self.rowImagePixels) {
                item.setImage(image)
            }
        }
        rebuildFeedsTab()
    }

    private func rebuildFeedsTab() {
        let feeds = FeedStore.shared.feeds
        let items = feeds.map { feed -> CPListItem in
            let item = CPListItem(text: feed.name, detailText: "\(feed.kind.title) · Tap for live view")
            item.handler = { [weak self] _, completion in
                completion()
                self?.pushFeedLive(feed)
            }
            return item
        }
        feedsTemplate.updateSections([
            CPListSection(items: items.isEmpty
                ? [CPListItem(text: "No feeds yet", detailText: "iPhone › Settings › Video Feeds")]
                : items)
        ])
    }

    /// Row thumbnails at the size CarPlay draws them (`CPListItem.maximumImageSize` is in points).
    private static var rowImagePixels: CGFloat { CPListItem.maximumImageSize.width * 3 }
    /// Decoded list thumbnails by review id — a refresh only fetches rows it hasn't seen.
    private var rowImages: [String: UIImage] = [:]

    private static func sizedFrameURL(_ url: URL, height: Int) -> URL? {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "height", value: String(height))]
        return comps?.url
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

    // MARK: - Alert detail (snapshot + info)

    @MainActor
    private func pushAlertDetail(_ review: FrigateReviewItem, client: FrigateClient) async {
        let subject = review.data?.subLabels?.first ?? review.data?.objects?.first ?? "Activity"
        var infoRows: [CPListItem] = [CPListItem(text: "Camera", detailText: titleize(review.camera))]
        if let zones = review.data?.zones, !zones.isEmpty {
            infoRows.append(CPListItem(text: "Zone", detailText: zones.map(titleize).joined(separator: ", ")))
        }
        infoRows.append(CPListItem(text: "When", detailText: relative(review.startTime)))
        let liveRow = CPListItem(text: "Live view", detailText: "Watch \(titleize(review.camera)) now")
        liveRow.handler = { [weak self] _, completion in
            completion()
            self?.pushCameraLive(review.camera, client: client)
        }
        infoRows.append(liveRow)

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

    // MARK: - Near-live (template mode)

    /// A Frigate camera: `latest.jpg` (server-resized) about once a second into the biggest picture
    /// a list template can show. In window mode the same tap simply plays the camera's MJPEG feed
    /// full screen.
    @MainActor
    private func pushCameraLive(_ name: String, client: FrigateClient) {
        if window != nil {
            let feed = Feed(name: titleize(name), url: client.mjpegURL(camera: name), kind: .mjpeg, usesFrigateAuth: true)
            CarVideoSession.shared.play(feed)
            interfaceController?.popToRootTemplate(animated: true, completion: nil)
            return
        }
        beginLive(title: titleize(name))
        liveTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                let started = Date()
                if let url = Self.sizedFrameURL(client.latestFrameURL(camera: name), height: 720),
                   let data = try? await client.imageData(from: url),
                   let image = await Task.detached(priority: .userInitiated, operation: { RemoteImage.downsample(data, maxPixel: 1000) }).value {
                    failures = 0
                    self?.showLiveFrame(image)
                } else {
                    failures += 1
                    if failures >= 3 { self?.showLiveMessage("Offline — retrying…") }
                }
                // ~1 fps, slower when the server is slow (never more than half the time in flight).
                let elapsed = Date().timeIntervalSince(started)
                let wait = max(1.0, min(5.0, elapsed * 2)) + (failures >= 3 ? 4 : 0)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    /// A user feed: `CarVideoSession` plays it (the phone may be showing it too) and hands this
    /// screen a downsampled frame about once a second.
    @MainActor
    private func pushFeedLive(_ feed: Feed) {
        if window != nil {
            CarVideoSession.shared.play(feed)
            interfaceController?.popToRootTemplate(animated: true, completion: nil)
            return
        }
        beginLive(title: feed.name)
        CarVideoSession.shared.frameSampler = { [weak self] image in self?.showLiveFrame(image) }
        if case .feed(let current) = CarVideoSession.shared.source, current == feed, CarVideoSession.shared.isStreaming {
            // Already playing (on the phone) — frames start arriving on their own.
        } else {
            CarVideoSession.shared.play(feed)
        }
        liveTask = Task { [weak self] in
            // Watch the session for a failure so the screen never sits on "Connecting…".
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                if case .failed(let message) = CarVideoSession.shared.state { self?.showLiveMessage("Offline — \(message)") }
            }
        }
    }

    @MainActor
    private func beginLive(title: String) {
        stopLive()
        liveTitle = title
        let template = CPListTemplate(title: title, sections: [messageSection("Connecting…")])
        liveTemplate = template
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    @MainActor
    private func showLiveFrame(_ image: UIImage) {
        guard let liveTemplate else { return }
        liveTemplate.updateSections([liveSection(image, label: liveTitle)])
    }

    @MainActor
    private func showLiveMessage(_ text: String) {
        liveTemplate?.updateSections([messageSection(text)])
    }

    @MainActor
    private func stopLive() {
        liveTask?.cancel()
        liveTask = nil
        liveTemplate = nil
        if CarVideoSession.shared.frameSampler != nil {
            CarVideoSession.shared.frameSampler = nil
            // Leave the feed running only if the phone is still showing it.
            if !CarVideoSession.shared.hasViewers { CarVideoSession.shared.stop() }
        }
    }

    /// The largest picture CarPlay draws in a list: on iOS 26 a full-height card element; before
    /// that, the image-row grid. Letterboxed on black so a wide camera isn't cropped.
    private func liveSection(_ image: UIImage, label: String) -> CPListSection {
        let tile = squarePadded(image)
        let row: CPListImageRowItem
        if #available(iOS 26.0, *) {
            let card = CPListImageRowItemCardElement(image: tile, showsImageFullHeight: true, title: label, subtitle: nil, tintColor: nil)
            row = CPListImageRowItem(text: nil, cardElements: [card], allowsMultipleLines: false)
        } else {
            row = Self.legacyImageRow(text: label, images: [tile])
        }
        row.listImageRowHandler = { _, _, completion in completion() }
        return CPListSection(items: [row])
    }

    @available(iOS, deprecated: 26.0)   // the pre-26 image row; silences the SDK's deprecation on the fallback path
    private static func legacyImageRow(text: String, images: [UIImage]) -> CPListImageRowItem {
        CPListImageRowItem(text: text, images: images)
    }

    // MARK: - Snapshot section (alert detail)

    @MainActor
    private func snapshotSection(url: URL?, client: FrigateClient, label: String) async -> CPListSection? {
        guard let url,
              let data = try? await client.imageData(from: url),
              let image = RemoteImage.downsample(data, maxPixel: 600) else { return nil }   // ImageIO, never the full frame
        return liveSection(image, label: label)
    }

    /// Letterbox an image onto a black square so it fills a CarPlay image tile without cropping.
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

// MARK: - Template lifecycle

extension CarPlaySceneDelegate: CPInterfaceControllerDelegate {
    func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        // Leaving the near-live screen stops its polling / frame sampling immediately.
        if let liveTemplate, aTemplate === liveTemplate, interfaceController?.templates.contains(where: { $0 === liveTemplate }) != true {
            Task { @MainActor in self.stopLive() }
        }
    }
}

// MARK: - Map template (window mode)

extension CarPlaySceneDelegate: CPMapTemplateDelegate {
    func mapTemplate(_ mapTemplate: CPMapTemplate, didEndPanGestureWithVelocity velocity: CGPoint) {
        // A tap on the video (a "pan" with no velocity) toggles fit / fill.
        if abs(velocity.x) < 30, abs(velocity.y) < 30 { videoVC.toggleFill() }
    }
}
