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
    case cameras   // jump to the Cameras tab (e.g. Siri "Show my cameras")
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
    /// No `oldValue` guard on purpose: the notification-service extension bumps the
    /// icon badge per push, so the in-app count and the icon can diverge. Re-syncing
    /// on every assignment (15s poll, "Review All", launch) means the icon always
    /// converges to the truth — including clearing to 0 when there's nothing to review.
    @Published var unreviewedCount: Int = 0 {
        didSet { updateAppBadge() }
    }
    /// Active bounding boxes per camera, keyed by camera name, auto-cleared on event end.
    /// Republished at most ~7 Hz (see `scheduleDetectionFlush`) — the raw WebSocket feed mutates
    /// this several times per second per tracked object, and every mutation re-renders EVERY view
    /// observing AppState (Settings, Search, the tab bar…). Coalescing kills that app-wide churn.
    @Published private(set) var liveDetections: [String: [LiveDetection]] = [:]
    /// Working copy that absorbs the high-frequency updates; flushed into `liveDetections` on a tick.
    private var pendingDetections: [String: [LiveDetection]] = [:]
    private var detectionFlushScheduled = false
    /// True when the birdseye composite stream is available in go2rtc.
    @Published var hasBirdseye = false
    /// Camera names with a `<name>_twoway` go2rtc stream — eligible for push-to-talk.
    @Published var twoWayCameras: Set<String> = []
    /// Whether the user is signed into their ApexSight cloud account.
    @Published var accountSignedIn: Bool = false

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

    // Removed in the nonisolated deinit; removeObserver is thread-safe.
    private nonisolated(unsafe) var quickActionObserver: NSObjectProtocol?

    init() {
        session = keychain.loadSession()
        eventStream.onEvent = { [weak self] event in
            self?.handleStreamEvent(event)
        }
        WatchSyncManager.shared.activate()
        // A Home Screen quick action stashes a pending deep link and posts this; consume it
        // now (a warm tap doesn't change scenePhase, so the .active path wouldn't fire).
        quickActionObserver = NotificationCenter.default.addObserver(
            forName: QuickActions.didTrigger, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.consumePendingIntentLink() }
        }
    }

    deinit {
        if let quickActionObserver { NotificationCenter.default.removeObserver(quickActionObserver) }
    }

    /// Mirrors the active Frigate base URL + token into the app group so the
    /// notification service extension can authenticate snapshot/GIF downloads for
    /// remote pushes that don't carry a token (the HA bridge has no user token).
    private func mirrorSessionToAppGroup() {
        let defaults = UserDefaults(suiteName: ApexAppGroup.identifier)
        if let session {
            defaults?.set(session.baseURL.absoluteString, forKey: "apex.frigateBaseURL")
            // The token is a secret: store it in the shared Keychain access group, not in the
            // App-Group plist. The base URL is not sensitive and stays in defaults.
            SharedTokenStore.save(session.token)
        } else {
            defaults?.removeObject(forKey: "apex.frigateBaseURL")
            SharedTokenStore.clear()
        }
        // Belt-and-suspenders: clear any token left in the plist by an older build that mirrored
        // it there, so the secret doesn't linger after this migration.
        defaults?.removeObject(forKey: "apex.frigateToken")
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
                // Recover a camera wall that a prior full refresh failed to load (e.g. a
                // transient outage at launch). refreshAlerts only reloads alerts, so once
                // it succeeds — proving connectivity is back — re-run the full refresh to
                // clear the stale error and fill the wall, instead of stranding the user
                // on the error card until they pull to refresh.
                if self?.isReachable == true, self?.cameras.isEmpty == true, self?.errorMessage != nil {
                    await self?.refresh()
                }
                self?.syncRelayGateIfChanged()
                self?.syncRecapIfChanged()
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
    /// Last recap schedule we pushed to the relay, so we only POST when it changes.
    private var lastSyncedRecap: String?

    /// Mirrors the Daily Recap schedule to the relay so the summary fires at the chosen
    /// local time with the app closed. Idempotent — only POSTs when the schedule changes.
    func syncRecapIfChanged() {
        let offset = TimeZone.current.secondsFromGMT()
        let signature = "\(RecapSettings.enabled)|\(RecapSettings.hour)|\(RecapSettings.minute)|\(offset)"
        guard signature != lastSyncedRecap else { return }
        lastSyncedRecap = signature

        let relayURL = DeviceTokenStore.relayURL
        let pairing = DeviceTokenStore.ensurePairingCode()
        guard !relayURL.isEmpty, !pairing.isEmpty else { return }
        Task {
            try? await RelayClient.syncRecap(
                relayURL: relayURL, pairingCode: pairing,
                enabled: RecapSettings.enabled, hour: RecapSettings.hour,
                minute: RecapSettings.minute, tzOffset: offset
            )
        }
    }

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
            if eventSignature(e) != eventSignature(events) { events = e; SpotlightIndexer.index(e) }
            if reviewsChanged { cacheLatestAlertForWidget() }
            // Badge = the un-reviewed ALERTS currently in the list, so it always matches
            // what you see and clearing them drops it to zero — not the entire retained
            // server history (which could be thousands of never-reviewed old alerts).
            unreviewedCount = visible.filter { $0.severity == "alert" }.count
            isReachable = true
        } catch {
            // Token expired mid-session: silently re-login once, then retry so the
            // live lists keep updating instead of quietly going stale.
            if error.isUnauthorized, retryOnAuthFailure, await reauthenticate() {
                await refreshAlerts(retryOnAuthFailure: false)
            } else if !error.isCancellation && !(error is DecodingError) {
                // Network/server down: keep the last-known lists, flag offline. A DecodingError
                // means the server IS up but returned unexpected data — don't lie "offline";
                // keep the last lists and let the next poll recover.
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
        case .event(let item, let change):
            upsertEvent(item)
            updateLiveDetection(item, change: change)
        case .review(let item, let change):
            handleReview(item, change: change)
        }
    }

    private func updateLiveDetection(_ item: FrigateEvent, change: ChangeType) {
        guard let box = item.box, box.count == 4,
              let w = item.frameWidth, w > 0,
              let h = item.frameHeight, h > 0 else {
            if change == .end {
                pendingDetections[item.camera]?.removeAll { $0.id == item.id }
                if pendingDetections[item.camera]?.isEmpty == true { pendingDetections.removeValue(forKey: item.camera) }
                scheduleDetectionFlush()
            }
            return
        }
        let normBox = CGRect(
            x: box[0] / w, y: box[1] / h,
            width: (box[2] - box[0]) / w, height: (box[3] - box[1]) / h
        )
        let det = LiveDetection(id: item.id, label: item.displayLabel, normBox: normBox)
        var current = pendingDetections[item.camera] ?? []
        current.removeAll { $0.id == item.id }
        if change != .end { current.append(det) }
        if current.isEmpty { pendingDetections.removeValue(forKey: item.camera) } else { pendingDetections[item.camera] = current }
        scheduleDetectionFlush()
    }

    /// Publish the coalesced detections at most ~7 Hz so a burst of WebSocket frames re-renders the
    /// UI a few times a second, not dozens. Smooth enough for bounding boxes; keeps the rest of the
    /// app (Settings/Search) from redrawing on every frame during active motion.
    private func scheduleDetectionFlush() {
        guard !detectionFlushScheduled else { return }
        detectionFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self else { return }
            self.detectionFlushScheduled = false
            if self.liveDetections != self.pendingDetections {
                self.liveDetections = self.pendingDetections
            }
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
        // Keep the Review tab + app-icon badge instant on WebSocket-delivered alerts
        // (same definition the poller uses), instead of lagging up to 15s.
        unreviewedCount = reviews.filter { $0.severity == "alert" }.count

        // Live Activity: when instant push is active the RELAY starts/updates the incident
        // Live Activity (so it appears even with the app closed, and we don't double it).
        // Without a relay token, the app drives it itself as the in-app fallback.
        if item.severity == "alert", !DeviceTokenStore.hasRemotePush {
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

        // Single push path: when the relay is active it delivers this alert as a push —
        // shown in-app by the system banner (willPresent) and on the Lock Screen when
        // closed — so we DON'T also raise the custom in-app banner or a local
        // notification, which would double it. The in-app banner + local notification
        // are the fallback only when there's no relay/APNs token.
        guard !DeviceTokenStore.hasRemotePush else {
            cacheLatestAlertForWidget()
            return
        }

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
            // Request permission AND register for remote push now — a fresh sign-in must get an
            // APNs token immediately, not wait for the next background→foreground cycle.
            PushRegistrar.ensureRegistered()
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
            case .message(let text):
                return text
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
        // Coalesce concurrent 401s (the 15s poller, refresh(), and each tab's .task can all
        // hit an expired token at once) into a single login round-trip + one keychain/session
        // write, instead of N parallel logins racing each other.
        if let reauthTask { return await reauthTask.value }
        guard let session, let password = session.password, !password.isEmpty else { return false }
        let task = Task { [weak self] () -> Bool in
            do {
                let client = FrigateClient(baseURL: session.baseURL)
                let token = try await client.login(username: session.username, password: password)
                let next = FrigateSession(
                    baseURL: session.baseURL,
                    username: session.username,
                    token: token,
                    password: password
                )
                self?.keychain.save(session: next)
                self?.session = next
                return true
            } catch {
                return false
            }
        }
        reauthTask = task
        let result = await task.value
        reauthTask = nil
        return result
    }

    /// In-flight token refresh, so concurrent 401s share one login instead of stampeding.
    private var reauthTask: Task<Bool, Never>?

    /// In-flight full refresh, so concurrent callers coalesce into one network round-trip.
    private var refreshTask: Task<Void, Never>?

    /// Bumped on every sign-out / server switch. Long-running background work (the capability
    /// probe) and the refresh-task bookkeeping capture the generation at entry and bail before
    /// publishing if it changed — so a probe that started on the previous server can't land its
    /// results over the new server, and a stale caller can't nil out a newer refresh task.
    private var serverGeneration = 0

    func refresh() async {
        // At cold launch several tabs' `.task` and the foreground poller can all call refresh()
        // at once; without coalescing that's 2-3 racing full fan-outs (cameras+events+reviews+
        // labels+stats+logs+streams) on the same short-timeout session. Share one.
        if let refreshTask {
            await refreshTask.value
            return
        }
        let gen = serverGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refresh(retryOnAuthFailure: true)
        }
        refreshTask = task
        await task.value
        // Only clear if a server switch/sign-out hasn't replaced this task in the meantime —
        // otherwise a stale caller resuming after its cancelled task would wipe the tracking of
        // a newer refresh, defeating coalescing and leaving it uncancellable.
        if serverGeneration == gen { refreshTask = nil }
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
            async let nextStreams = client.go2rtcStreams()
            // NOTE: stats + logs are intentionally NOT fetched here. /api/logs/frigate is a heavy
            // text blob and both are read only by SystemHealthView (Settings), so refresh() — which
            // runs on every launch / foreground / poll — must not pay for them. Stats stay fresh via
            // the live WebSocket; SystemHealthView fetches both itself via loadSystemHealth().

            let loadedCameras = try await nextCameras
            cameras = loadedCameras
            prewarmSnapshots()
            // refresh() runs on every foreground / pull / poll, so only re-publish the camera
            // list to the system when it actually changed — donating App Intents parameters and
            // re-indexing Spotlight on every poll is wasted work on a hot path.
            let cameraNames = loadedCameras.map(\.name)
            let cameraNamesChanged = cameraNames != SharedSnapshotStore.loadCameraNames()
            // Mirror camera names to the app group so Siri/Watch/CarPlay can list them.
            SharedSnapshotStore.saveCameraNames(cameraNames)
            if cameraNamesChanged {
                // Refresh the Home Screen quick actions (per-camera "Open <camera>") only when the
                // set actually changes — not on every 15s poll, which needlessly hit UIKit.
                QuickActions.update(cameras: loadedCameras)
                // Tell App Intents the camera parameter options changed so Siri/Shortcuts refresh
                // their predicted "Check the <camera>" suggestions instead of going stale.
                ApexShortcuts.updateAppShortcutParameters()
                // Index cameras into Spotlight so typing "front door" opens that camera.
                if #available(iOS 18.0, *) {
                    let entities = loadedCameras.map { CameraEntity(id: $0.name) }
                    Task { try? await CSSearchableIndex.default().indexAppEntities(entities) }
                }
            }
            events = (try? await nextEvents) ?? events
            if let r = try? await nextReviews {
                reviews = visibleReviews(r)
            }
            labels = (try? await nextLabels) ?? labels
            subLabels = (try? await nextSubLabels) ?? subLabels

            let streams = (try? await nextStreams) ?? [:]
            hasBirdseye = streams["birdseye"] != nil
            twoWayCameras = Set(streams.keys.filter { $0.hasSuffix("_twoway") }
                .map { String($0.dropLast("_twoway".count)) })
            // Fire-and-forget so refresh() (and the launch spinner) doesn't block on an extra
            // image round-trip for the widget snapshot.
            Task { await cacheWidgetSnapshot(from: loadedCameras) }
            capabilities = buildBaseCapabilities(cameras: loadedCameras, streams: streams)
            // NOTE: capability diagnostics (latest-frame / recordings / PTZ probes) are NOT run
            // here. Firing N×3 requests at the Frigate server the moment the wall is loading its
            // live streams measurably slowed first-frame time. PTZ is now detected lazily, per
            // camera, only when you open it full-screen (see LiveStreamView); the deeper probe
            // stays behind the manual Diagnostics button on the Health screen.
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

    /// Fetch the heavy stats + logs only when SystemHealthView (Settings) is actually open —
    /// keeps them off the launch/refresh hot path.
    func loadSystemHealth() async {
        guard let client else { return }
        if let s = try? await client.stats() { stats = s }
        recentLogs = (try? await client.logs()) ?? recentLogs
    }

    /// Cameras whose snapshot prewarm is in flight, so repeated calls don't re-download.
    private var prewarmingCameras: Set<String> = []

    /// Warm the snapshot cache for every camera so live grids paint a real frame
    /// INSTANTLY (and never flash black) — even tiles you haven't scrolled to yet, and
    /// even right after a stream is torn down. Each fetch is small + concurrent, so the
    /// whole wall has something to show within a beat of opening.
    func prewarmSnapshots() {
        guard let client else { return }
        for name in cameras.map(\.name) {
            let url = client.latestFrameURL(camera: name)
            // Skip if already cached OR a fetch is already in flight (fast tab flaps used to
            // re-dispatch every camera's download). maxPixel matches RemoteImage's default so
            // the warmed image is exactly what the cell reuses.
            if ImageCache.shared.image(for: url) != nil || prewarmingCameras.contains(name) { continue }
            prewarmingCameras.insert(name)
            Task { @MainActor in
                defer { prewarmingCameras.remove(name) }
                guard let data = try? await client.imageData(from: url) else { return }
                // Downsample off the main actor — N concurrent 1000px JPEG decodes on main
                // at the exact moment the wall is trying to render is the open-the-wall hitch.
                guard let image = await Task.detached(priority: .utility, operation: {
                    RemoteImage.downsample(data, maxPixel: 1000)
                }).value else { return }
                ImageCache.shared.insert(image, for: url)
            }
        }
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
        // Carry forward the probe-only flags (PTZ, recordings) from a prior diagnostic pass so
        // the 15s poll's base rebuild doesn't wipe them back to false — that reset is why the
        // PTZ control vanished after appearing: `hasPtz` is set by diagnostics, then the very
        // next poll erased it. Keyed by camera name; falls back to false for never-diagnosed cams.
        let prior = Dictionary(uniqueKeysWithValues: capabilities.map { ($0.camera, $0) })
        return cameras.map { camera in
            let known = prior[camera.name]
            return CameraCapability(
                camera: camera.name,
                hasLatestFrame: true,
                hasRecordings: known?.hasRecordings ?? false,
                hasPtz: known?.hasPtz ?? false,
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

            // Accurate PTZ: only true when the camera reports real pan/tilt/zoom features, not
            // just a 200 from ptz/info (which every camera returns).
            capability.hasPtz = await client.ptzCapable(camera: camera.name)

            output.append(capability)
        }

        return output.sorted { $0.camera < $1.camera }
    }

    /// Cancels any in-flight full refresh / token reauth so a network round-trip that
    /// captured the *previous* server's `client` can't resume and publish its cameras/events
    /// over the just-cleared state. Cancellation propagates to the `async let` children in
    /// `refresh(retryOnAuthFailure:)`, which then throw `CancellationError` (ignored) instead
    /// of assigning stale data. Without this, switching servers briefly showed the old
    /// household's wall until the next 15s poll corrected it.
    private func cancelInFlightServerWork() {
        serverGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        reauthTask?.cancel()
        reauthTask = nil
    }

    func switchTo(session: FrigateSession) {
        stopRealtime()
        stopForegroundPolling()
        cancelInFlightServerWork()
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
        cancelInFlightServerWork()
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
    /// Also persists it to the app group so the notification extension increments from
    /// the correct base when a push lands while the app is closed.
    private func updateAppBadge() {
        let count = unreviewedCount
        UserDefaults(suiteName: ApexAppGroup.identifier)?.set(count, forKey: "apex.badgeCount")
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
        case "cameras":
            deepLink = .cameras
        case "latest":
            // Home Screen quick action / Control Center: jump to the most recent alert,
            // else just open the camera wall.
            if let newest = reviews.first {
                deepLink = .review(newest.id)
            } else {
                deepLink = .cameras
            }
        case "snooze":
            // Silence all alerts for an hour and mirror the gate to the relay so app-closed
            // pushes are quieted too (see [[relay-gate-must-sync-on-app-closed-snooze]]).
            let until = Date().addingTimeInterval(60 * 60)
            GlobalSnooze.snooze(until: until)
            Task { await RelayGate.sync(snoozedUntil: until.timeIntervalSince1970) }
        #if DEBUG
        case "debug":
            // Deterministic triggers for surfaces that need a real alert to fire, reachable
            // via `apex://debug?action=…` stashed in the app group + consumed on cold launch
            // (handy when synthetic taps aren't available). DEBUG-only.
            let camera = items.first(where: { $0.name == "camera" })?.value
                ?? cameras.first?.name ?? "front_door"
            switch items.first(where: { $0.name == "action" })?.value {
            case "liveactivity": DebugTriggers.fireLiveActivity(camera: camera)
            case "watchpush": DebugTriggers.fireWatchPush(camera: camera)
            default: break
            }
        #endif
        default:
            break
        }
    }
}
