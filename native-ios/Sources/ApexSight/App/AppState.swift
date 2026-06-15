import Foundation
import SwiftUI
import WidgetKit

enum AppDeepLink: Hashable {
    case review(String)
    case event(String)
    case camera(String)
}

extension Error {
    /// True for URLSession/Task cancellations that shouldn't surface as user-facing errors.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        let nsError = self as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var session: FrigateSession? {
        didSet { mirrorSessionToAppGroup() }
    }
    @Published var cameras: [FrigateCamera] = []
    @Published var events: [FrigateEvent] = []
    @Published var reviews: [FrigateReviewItem] = []
    @Published var labels: [String] = []
    @Published var subLabels: [String] = []
    @Published var stats: FrigateStats?
    @Published var capabilities: [CameraCapability] = []
    @Published var recentLogs: [String] = []
    @Published var deepLink: AppDeepLink?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isLive = false
    @Published var liveBanner: LiveBannerModel?

    let keychain = KeychainStore()
    let notificationPrefs = NotificationPreferencesStore()
    private let eventStream = FrigateEventStream()

    /// Reviews the user just marked viewed — filtered out of fetched results so they
    /// don't flash back in while the server catches up to the viewed state.
    private var locallyViewedIDs: Set<String> = []
    /// Foreground poller — guarantees new alerts/events appear without restarting the app,
    /// even when the WebSocket can't be established through the user's reverse proxy.
    private var pollTask: Task<Void, Never>?

    var client: FrigateClient? {
        guard let session else { return nil }
        return FrigateClient(session: session)
    }

    init() {
        session = keychain.loadSession()
        eventStream.onEvent = { [weak self] event in
            self?.handleStreamEvent(event)
        }
    }

    /// Mirrors the active Frigate base URL + token into the app group so the
    /// notification service extension can authenticate snapshot/GIF downloads for
    /// remote pushes that don't carry a token (the HA bridge has no user token).
    private func mirrorSessionToAppGroup() {
        let defaults = UserDefaults(suiteName: ApexAppGroup.identifier)
        if let session {
            defaults?.set(session.baseURL.absoluteString, forKey: "apex.frigateBaseURL")
            defaults?.set(session.token, forKey: "apex.frigateToken")
        } else {
            defaults?.removeObject(forKey: "apex.frigateBaseURL")
            defaults?.removeObject(forKey: "apex.frigateToken")
        }
    }

    // MARK: - Real-time

    func startRealtime() {
        guard let session else { return }
        eventStream.connect(session: session)
    }

    func stopRealtime() {
        eventStream.disconnect()
    }

    /// Polls recent reviews + events every 15s while the app is foregrounded so the lists
    /// stay live without a restart. The WebSocket (when it connects) updates instantly;
    /// this is the reliable fallback for proxies that don't pass `/ws`.
    func startForegroundPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAlerts()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    func stopForegroundPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Lightweight refresh of just the things that need to feel live: reviews + events.
    func refreshAlerts() async {
        guard let client else { return }
        async let nextReviews = client.reviews(limit: 30)
        async let nextEvents = client.events(limit: 50)
        if let r = try? await nextReviews {
            reviews = r.filter { !locallyViewedIDs.contains($0.id) }
        }
        if let e = try? await nextEvents {
            events = e
        }
        cacheLatestAlertForWidget()
    }

    /// Marks every currently-shown review as handled in one tap (Frigate `reviews/viewed`).
    func markAllReviewsViewed() async {
        guard let client else { return }
        let ids = reviews.map(\.id)
        guard !ids.isEmpty else { return }
        do {
            try await client.markReviewsViewed(ids: ids)
            locallyViewedIDs.formUnion(ids)
            reviews.removeAll { ids.contains($0.id) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Caches a short feed of recent reviews (label + camera + time, newest-first) plus a
    /// single hero thumbnail (the newest event) into the app group, then reloads the widget
    /// timeline so the home-screen widget shows a recent-activity list — no live streaming.
    private func cacheLatestAlertForWidget() {
        guard let client else { return }
        let recent = Array(reviews.prefix(8))
        guard !recent.isEmpty else { return }

        let alerts: [SharedAlert] = recent.map { review in
            SharedAlert(
                id: review.id,
                label: review.data?.objects?.first ?? "object",
                subLabel: review.data?.subLabels?.first,
                camera: review.camera,
                severity: review.severity ?? "alert",
                when: Date(timeIntervalSince1970: review.startTime ?? Date().timeIntervalSince1970),
                imageFileName: nil
            )
        }
        let thumbURL = recent.first.flatMap { client.reviewThumbnailURL(review: $0) }

        Task {
            var heroData: Data?
            if let thumbURL { heroData = try? await client.imageData(from: thumbURL) }
            SharedSnapshotStore.saveRecentAlerts(alerts, heroImageData: heroData)
            // Keep the single-latest-alert store in sync for any legacy reader.
            if let first = alerts.first {
                SharedSnapshotStore.saveLatestAlert(
                    label: first.label, subLabel: first.subLabel, camera: first.camera,
                    severity: first.severity, when: first.when, imageData: heroData
                )
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func handleStreamEvent(_ event: StreamEvent) {
        switch event {
        case .connected:
            isLive = true
        case .disconnected:
            isLive = false
        case .stats(let s):
            stats = s
        case .event(let item, _):
            upsertEvent(item)
        case .review(let item, let change):
            handleReview(item, change: change)
        }
    }

    private func upsertEvent(_ item: FrigateEvent) {
        events.removeAll { $0.id == item.id }
        events.insert(item, at: 0)
        if events.count > 50 { events = Array(events.prefix(50)) }
    }

    private func handleReview(_ item: FrigateReviewItem, change: ChangeType) {
        guard !locallyViewedIDs.contains(item.id) else { return }
        let wasNew = !reviews.contains { $0.id == item.id }
        reviews.removeAll { $0.id == item.id }

        if change == .end {
            // Only dismiss the Live Activity for alert reviews — detection reviews ending
            // should not kill an ongoing alert incident's Dynamic Island banner.
            if item.severity == "alert" { IncidentActivityController.end() }
            return
        }

        reviews.insert(item, at: 0)
        if reviews.count > 30 { reviews = Array(reviews.prefix(30)) }

        // Keep the Live Activity up-to-date on both new and update events (e.g., more
        // objects detected in the same incident). The guard below still limits banner +
        // notification to brand-new alert-severity items only.
        if item.severity == "alert" {
            IncidentActivityController.startOrUpdate(review: item)
        }

        guard wasNew, change == .new, item.severity == "alert" else { return }

        let label = item.data?.objects?.first ?? "object"
        let zones = item.data?.zones ?? []
        guard notificationPrefs.shouldDeliver(camera: item.camera, label: label, zones: zones) else { return }
        guard LastSeenStore.isNew(item.id) else { return }
        LastSeenStore.markSeen([item.id])

        liveBanner = LiveBannerModel(
            id: item.id,
            title: NotificationCopy.title(for: item),
            body: NotificationCopy.body(for: item),
            reviewID: item.id
        )

        if let client, let session {
            Task {
                // Frigate creates reviews before events finish processing, so the
                // WebSocket payload often has empty data.detections — which means
                // reviewGifURL/reviewSnapshotURL return nil and the notification
                // has no attachment. Fetch the full review first so we get detections.
                let notifyReview: FrigateReviewItem
                if item.data?.detections?.isEmpty != false {
                    notifyReview = (try? await client.review(id: item.id)) ?? item
                } else {
                    notifyReview = item
                }
                await LocalAlertNotifier.notify(review: notifyReview, client: client, session: session)
            }
        }

        cacheLatestAlertForWidget()
    }

    func signIn(baseURL: String, username: String, password: String) async {
        isLoading = true
        errorMessage = nil
        do {
            let normalized = try FrigateSession.normalizedBaseURL(baseURL)
            let client = FrigateClient(baseURL: normalized)
            let token = try await client.login(username: username, password: password)
            let next = FrigateSession(baseURL: normalized, username: username, token: token, password: password)
            keychain.save(session: next)
            session = next
            await refresh()
            startRealtime()
            startForegroundPolling()
            Task { _ = try? await NativeNotificationManager.requestPermission() }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Silently refreshes the `frigate_token` JWT by re-running the stored login.
    /// Called when a stream/API request 401s mid-session (token expiry). Reuses the
    /// existing credentials — never prompts or builds a second credential store.
    /// Returns `true` if a fresh token was obtained.
    @discardableResult
    func reauthenticate() async -> Bool {
        guard let session, let password = session.password, !password.isEmpty else { return false }
        do {
            let client = FrigateClient(baseURL: session.baseURL)
            let token = try await client.login(username: session.username, password: password)
            let next = FrigateSession(
                baseURL: session.baseURL,
                username: session.username,
                token: token,
                password: password
            )
            keychain.save(session: next)
            self.session = next
            return true
        } catch {
            return false
        }
    }

    func refresh() async {
        guard let client else { return }
        isLoading = true
        errorMessage = nil
        do {
            async let nextCameras = client.cameras()
            async let nextEvents = client.events(limit: 50)
            async let nextReviews = client.reviews(limit: 30)
            async let nextLabels = client.labels()
            async let nextSubLabels = client.subLabels()
            async let nextStats = client.stats()
            async let nextLogs = client.logs()
            async let nextStreams = client.go2rtcStreams()

            let loadedCameras = try await nextCameras
            cameras = loadedCameras
            events = (try? await nextEvents) ?? events
            if let r = try? await nextReviews {
                reviews = r.filter { !locallyViewedIDs.contains($0.id) }
            }
            labels = (try? await nextLabels) ?? labels
            subLabels = (try? await nextSubLabels) ?? subLabels
            if let s = try? await nextStats { stats = s }
            recentLogs = (try? await nextLogs) ?? recentLogs

            let streams = (try? await nextStreams) ?? [:]
            await cacheWidgetSnapshot(from: loadedCameras)
            capabilities = buildBaseCapabilities(cameras: loadedCameras, streams: streams)
        } catch {
            // Ignore transient cancellations (interrupted refreshes, view teardown).
            if !error.isCancellation {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    private func cacheWidgetSnapshot(from cameras: [FrigateCamera]) async {
        guard
            let client,
            let camera = cameras.first,
            let serverName = session?.baseURL.host()
        else {
            return
        }

        do {
            let data = try await client.imageData(from: client.latestFrameURL(camera: camera.name))
            SharedSnapshotStore.save(imageData: data, camera: camera.name, serverName: serverName)
        } catch {}
    }

    private func buildBaseCapabilities(cameras: [FrigateCamera], streams: [String: JSONValue]) -> [CameraCapability] {
        cameras.map { camera in
            CameraCapability(
                camera: camera.name,
                hasLatestFrame: true,
                hasGo2RtcStream: streams[camera.name] != nil,
                zones: camera.zones,
                objects: camera.objects
            )
        }
        .sorted { $0.camera < $1.camera }
    }

    func refreshCapabilityDiagnostics() async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }

        let diagnosed = await buildCapabilityDiagnostics(cameras: cameras, client: client)
        if !diagnosed.isEmpty {
            capabilities = diagnosed
        }
    }

    private func buildCapabilityDiagnostics(cameras: [FrigateCamera], client: FrigateClient) async -> [CameraCapability] {
        let knownCapabilities = Dictionary(uniqueKeysWithValues: capabilities.map { ($0.camera, $0) })
        var output: [CameraCapability] = []

        for camera in cameras {
            let known = knownCapabilities[camera.name]
            var capability = CameraCapability(
                camera: camera.name,
                hasGo2RtcStream: known?.hasGo2RtcStream ?? false,
                zones: camera.zones,
                objects: camera.objects
            )

            do {
                _ = try await client.imageData(from: client.latestFrameURL(camera: camera.name))
                capability.hasLatestFrame = true
            } catch {}

            do {
                capability.hasRecordings = !(try await client.recordings(camera: camera.name)).isEmpty
            } catch {}

            do {
                _ = try await client.ptzInfo(camera: camera.name)
                capability.hasPtz = true
            } catch {}

            output.append(capability)
        }

        return output.sorted { $0.camera < $1.camera }
    }

    func switchTo(session: FrigateSession) {
        stopRealtime()
        stopForegroundPolling()
        locallyViewedIDs.removeAll()
        self.session = session
        keychain.save(session: session)
        cameras = []
        events = []
        reviews = []
        labels = []
        subLabels = []
        stats = nil
        capabilities = []
        recentLogs = []
        Task {
            await refresh()
            startRealtime()
            startForegroundPolling()
        }
    }

    func signOut() {
        stopRealtime()
        stopForegroundPolling()
        locallyViewedIDs.removeAll()
        keychain.clear()
        session = nil
        cameras = []
        events = []
        reviews = []
        labels = []
        subLabels = []
        stats = nil
        capabilities = []
        recentLogs = []
    }

    func markReviewViewed(_ review: FrigateReviewItem) async {
        await markReviewViewed(id: review.id)
    }

    func markReviewViewed(id: String) async {
        guard let client else { return }
        do {
            try await client.markReviewsViewed(ids: [id])
            locallyViewedIDs.insert(id)
            reviews.removeAll { $0.id == id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme == "apex" else { return }

        let target = url.host ?? url.pathComponents.dropFirst().first
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []

        switch target {
        case "review":
            if let id = items.first(where: { $0.name == "id" })?.value {
                deepLink = .review(id)
            }
        case "event":
            if let id = items.first(where: { $0.name == "id" })?.value {
                deepLink = .event(id)
            }
        case "camera":
            if let name = items.first(where: { $0.name == "name" })?.value {
                deepLink = .camera(name)
            }
        default:
            break
        }
    }
}
