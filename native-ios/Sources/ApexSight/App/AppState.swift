import Foundation
import SwiftUI
import WidgetKit
import CoreSpotlight
import AppIntents
import UserNotifications

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

    /// True when the server rejected our credentials — i.e. the Frigate session
    /// token has expired and we should silently re-login before giving up.
    var isUnauthorized: Bool {
        if let frigate = self as? FrigateError, case .badResponse(let code) = frigate {
            return code == 401 || code == 403
        }
        let nsError = self as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorUserAuthenticationRequired
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
    /// Whether the server is currently reachable — driven by the 15s poller and full
    /// refreshes. False means our last fetch failed (network/server down), so the UI
    /// can show an offline indicator instead of silently serving stale data.
    @Published var isReachable = true
    @Published var liveBanner: LiveBannerModel?
    /// Un-reviewed alert count — drives the Review tab badge and the app-icon badge.
    @Published var unreviewedCount: Int = 0 {
        didSet { guard unreviewedCount != oldValue else { return }; updateAppBadge() }
    }

    let keychain = KeychainStore()
    let notificationPrefs = NotificationPreferencesStore()
    /// One shared store of notification triggers, read by the delivery gate and edited
    /// by every surface (Settings → Triggers and the per-event "Create Trigger") so
    /// edits are consistent and actually affect what's delivered.
    let triggerStore = NotificationTriggerStore()
    private let eventStream = FrigateEventStream()

    /// Reviews the user just marked viewed — filtered out of fetched results so they
    /// don't flash back in while the server catches up to the viewed state. Published +
    /// readable so the Review tab's on-demand detection list can exclude them too.
    @Published private(set) var locallyViewedIDs: Set<String> = []
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
        WatchSyncManager.shared.activate()
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
        // Idempotent — a fast background/foreground flap shouldn't stack pollers.
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAlerts()
                self?.syncRelayGateIfChanged()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    func stopForegroundPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Last arm/snooze gate we pushed to the relay, so we only POST when it changes.
    private var lastSyncedGate: String?

    /// Mirrors the current Disarm / Snooze state to the relay so app-closed pushes are
    /// suppressed while disarmed or snoozed — the relay counterpart of the in-app gate.
    /// Cheap and idempotent: only fires when the state actually changes. (Changes made
    /// from Siri/widgets while the app is fully closed sync on the next foreground.)
    func syncRelayGateIfChanged() {
        let disarmed = !ArmStateStore.notificationsActive
        let snoozedUntil = GlobalSnooze.until?.timeIntervalSince1970 ?? 0
        let signature = "\(disarmed)|\(Int(snoozedUntil))"
        guard signature != lastSyncedGate else { return }
        lastSyncedGate = signature

        let relayURL = DeviceTokenStore.relayURL
        let pairing = DeviceTokenStore.ensurePairingCode()
        guard !relayURL.isEmpty, !pairing.isEmpty else { return }
        Task {
            try? await RelayClient.syncGate(
                relayURL: relayURL, pairingCode: pairing,
                disarmed: disarmed, snoozedUntil: snoozedUntil
            )
        }
    }

    /// Lightweight refresh of just the things that need to feel live: reviews + events.
    func refreshAlerts(retryOnAuthFailure: Bool = true) async {
        guard let client else { return }
        do {
            async let nextReviews = client.reviews(limit: 30, reviewed: false)
            async let nextEvents = client.events(limit: 50)
            let r = try await nextReviews
            let e = try await nextEvents
            // Reassign only when something actually changed — but compare CONTENT
            // (id + severity + objects + sub-labels), not just ids, so a review that
            // gains a recognized sub-label (e.g. "Amazon") still updates the list,
            // the widget, and the lock screen.
            let visible = visibleReviews(r)
            let reviewsChanged = reviewSignature(visible) != reviewSignature(reviews)
            if reviewsChanged { reviews = visible }
            if eventSignature(e) != eventSignature(events) { events = e }
            if reviewsChanged { cacheLatestAlertForWidget() }
            // Accurate unreviewed-alert count for the badges (falls back to the loaded
            // alerts if the summary endpoint isn't available).
            if let count = try? await client.unreviewedAlertCount() {
                unreviewedCount = count
            } else {
                unreviewedCount = visible.filter { $0.severity == "alert" }.count
            }
            isReachable = true
        } catch {
            // Token expired mid-session: silently re-login once, then retry so the
            // live lists keep updating instead of quietly going stale.
            if error.isUnauthorized, retryOnAuthFailure, await reauthenticate() {
                await refreshAlerts(retryOnAuthFailure: false)
            } else if !error.isCancellation {
                // Network/server down: keep the last-known lists, flag offline.
                isReachable = false
            }
        }
    }

    /// Marks EVERY un-reviewed item on the server as handled — not just the ~30
    /// loaded — and persists it via Frigate's `reviews/viewed` API so they stay gone
    /// after relaunch. Pages through the full backlog and marks in chunks.
    func markAllReviewsViewed() async {
        guard let client else { return }
        do {
            var idSet = Set<String>()
            var before: Double? = nil
            // Page through the whole un-reviewed backlog (safety-capped).
            for _ in 0..<50 {
                let batch = try await client.reviews(limit: 200, reviewed: false, before: before)
                guard !batch.isEmpty else { break }
                let newIDs = batch.map(\.id).filter { !idSet.contains($0) }
                guard !newIDs.isEmpty else { break }   // no progress → stop
                idSet.formUnion(newIDs)
                guard batch.count >= 200, let oldest = batch.compactMap(\.startTime).min() else { break }
                before = oldest
            }

            let ids = Array(idSet)
            guard !ids.isEmpty else {
                reviews.removeAll()
                return
            }
            // Mark in chunks so a huge backlog doesn't blow the request body.
            for start in stride(from: 0, to: ids.count, by: 500) {
                let slice = Array(ids[start..<min(start + 500, ids.count)])
                try await client.markReviewsViewed(ids: slice)
            }
            locallyViewedIDs.formUnion(ids)
            reviews.removeAll()
            unreviewedCount = 0
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Drops anything the server already considers reviewed (and anything we just
    /// marked locally), so reviewed items never reappear after a relaunch.
    private func visibleReviews(_ items: [FrigateReviewItem]) -> [FrigateReviewItem] {
        items.filter { !locallyViewedIDs.contains($0.id) && !($0.hasBeenReviewed ?? false) }
    }

    /// Content fingerprint so list/widget refresh fires on real changes (new items,
    /// severity escalations, newly-recognized sub-labels) but not on identical polls.
    private func reviewSignature(_ items: [FrigateReviewItem]) -> [String] {
        items.map { item in
            let subs = (item.data?.subLabels ?? []).joined(separator: ",")
            let objs = (item.data?.objects ?? []).joined(separator: ",")
            return "\(item.id)|\(item.severity ?? "")|\(objs)|\(subs)"
        }
    }

    private func eventSignature(_ items: [FrigateEvent]) -> [String] {
        items.map { "\($0.id)|\($0.subLabel ?? "")|\($0.recognizedLicensePlate ?? "")" }
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
                imageFileName: nil,
                zone: review.data?.zones?.first
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
            // Mirror the same recent-activity feed to the paired Apple Watch.
            WatchSyncManager.shared.push(alerts: alerts, heroJPEG: heroData)
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
        reviews.removeAll { $0.id == item.id }

        // Already handled on the server (e.g. marked reviewed elsewhere) → keep it gone.
        if item.hasBeenReviewed == true { return }

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

        // Notify the first time a review reaches alert severity. This includes a
        // detection-severity review that later *escalates* to an alert — Frigate
        // delivers that as an .update (not a .new), so the old `change == .new`
        // guard silently swallowed it. LastSeenStore only ever records alerts, so
        // it's the dedup: a brand-new alert and an escalated one each fire exactly
        // once, while subsequent updates (more objects) refresh only the Live
        // Activity above, not a second banner.
        guard item.severity == "alert" else { return }

        let label = item.data?.objects?.first ?? "object"
        let zones = item.data?.zones ?? []
        guard notificationPrefs.shouldDeliver(
            camera: item.camera, label: label, zones: zones,
            score: 0, triggers: triggerStore.triggers
        ) else { return }
        guard LastSeenStore.isNew(item.id) else { return }
        LastSeenStore.markSeen([item.id])

        liveBanner = LiveBannerModel(
            id: item.id,
            title: NotificationCopy.title(for: item),
            body: NotificationCopy.body(for: item),
            reviewID: item.id
        )

        // When instant push is set up, the relay already delivers this alert — posting
        // a local notification too would be a duplicate. The in-app banner above still
        // shows. Local notifications remain the zero-setup fallback only when there's
        // no relay/APNs token.
        if !DeviceTokenStore.hasRemotePush, let client, let session {
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
            errorMessage = Self.signInErrorMessage(for: error)
        }
        isLoading = false
    }

    /// Turns the raw sign-in error into something actionable, so the user can tell a
    /// wrong password apart from an unreachable server instead of seeing a status code.
    static func signInErrorMessage(for error: Error) -> String {
        if let frigate = error as? FrigateError {
            switch frigate {
            case .loginFailed:
                return "Wrong username or password."
            case .invalidURL:
                return "That server address doesn't look right — include http:// or https://."
            case .badResponse(let code):
                if code == 401 || code == 403 { return "Wrong username or password." }
                return "Frigate returned an error (\(code)). Check that it's running and reachable."
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                 NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet, NSURLErrorDNSLookupFailed:
                return "Couldn't reach the server. Check the address and that you're on the right network."
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid:
                return "Secure connection failed — check the server's HTTPS certificate."
            default:
                break
            }
        }
        return error.localizedDescription
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
        await refresh(retryOnAuthFailure: true)
    }

    private func refresh(retryOnAuthFailure: Bool) async {
        guard let client else { return }
        isLoading = true
        errorMessage = nil
        do {
            async let nextCameras = client.cameras()
            async let nextEvents = client.events(limit: 50)
            async let nextReviews = client.reviews(limit: 30, reviewed: false)
            async let nextLabels = client.labels()
            async let nextSubLabels = client.subLabels()
            async let nextStats = client.stats()
            async let nextLogs = client.logs()
            async let nextStreams = client.go2rtcStreams()

            let loadedCameras = try await nextCameras
            cameras = loadedCameras
            // Mirror camera names to the app group so Siri/Watch/CarPlay can list them.
            SharedSnapshotStore.saveCameraNames(loadedCameras.map(\.name))
            // Index cameras into Spotlight so typing "front door" opens that camera.
            if #available(iOS 18.0, *) {
                let entities = loadedCameras.map { CameraEntity(id: $0.name) }
                Task { try? await CSSearchableIndex.default().indexAppEntities(entities) }
            }
            events = (try? await nextEvents) ?? events
            if let r = try? await nextReviews {
                reviews = visibleReviews(r)
            }
            labels = (try? await nextLabels) ?? labels
            subLabels = (try? await nextSubLabels) ?? subLabels
            if let s = try? await nextStats { stats = s }
            recentLogs = (try? await nextLogs) ?? recentLogs

            let streams = (try? await nextStreams) ?? [:]
            await cacheWidgetSnapshot(from: loadedCameras)
            capabilities = buildBaseCapabilities(cameras: loadedCameras, streams: streams)
            isReachable = true
        } catch {
            // Token expired mid-session: silently re-login once and retry the whole
            // refresh with a fresh client, so the user never lands on blank screens.
            if error.isUnauthorized, retryOnAuthFailure, await reauthenticate() {
                isLoading = false
                await refresh(retryOnAuthFailure: false)
                return
            }
            // Ignore transient cancellations (interrupted refreshes, view teardown).
            if !error.isCancellation {
                errorMessage = error.localizedDescription
                isReachable = false
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
        unreviewedCount = 0
        keychain.clear()
        // Clear the Watch so it doesn't keep showing the last household's alerts after sign-out.
        WatchSyncManager.shared.push(alerts: [], heroJPEG: nil)
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

    /// Mirrors the unreviewed-alert count onto the app icon (like Mail's unread badge).
    private func updateAppBadge() {
        let count = unreviewedCount
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(count) }
    }

    func markReviewViewed(_ review: FrigateReviewItem) async {
        if review.severity == "alert" { unreviewedCount = max(0, unreviewedCount - 1) }
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

    /// Applies an apex:// link an App Intent stashed in the app group before opening the
    /// app (Siri "show the front door"). Cleared once consumed so it fires only once.
    func consumePendingIntentLink() {
        let defaults = UserDefaults(suiteName: ApexAppGroup.identifier)
        guard let raw = defaults?.string(forKey: "apex.pendingIntentLink"),
              let url = URL(string: raw) else { return }
        defaults?.removeObject(forKey: "apex.pendingIntentLink")
        handleDeepLink(url)
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
