import Foundation
import SwiftUI
import WidgetKit
import CoreSpotlight
import AppIntents
import UserNotifications
import Network

enum AppDeepLink: Hashable {
    case review(String)
    case event(String)
    case camera(String)
    case cameras   // jump to the Cameras tab (e.g. Siri "Show my cameras")
    case activity  // jump to the Activity feed (e.g. tapping the Daily Recap push)
    case house     // open the House Mode control (Lock Screen widget / Control Center / Live Activity)
    case doorbell  // present the full-screen doorbell call (doorbell-ring push)
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

    /// True for a hard 404 — the resource doesn't exist (e.g. snapshot.jpg on a camera with
    /// snapshots disabled), so retries won't help and a fallback should be tried instead.
    var isNotFound: Bool {
        if let frigate = self as? FrigateError, case .badResponse(let code) = frigate {
            return code == 404
        }
        return false
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
    /// Staged copy of `events` for the WebSocket feed — same coalescing idea as
    /// `pendingDetections`. The raw `events` topic fires several times a second per
    /// tracked object during motion; publishing each one re-diffed the entire app.
    private var pendingEvents: [FrigateEvent]?
    private var eventFlushScheduled = false
    /// True when the birdseye composite stream is available in go2rtc.
    @Published var hasBirdseye = false
    /// Camera names with a `<name>_twoway` go2rtc stream — eligible for push-to-talk.
    @Published var twoWayCameras: Set<String> = []
    /// Camera names that actually have a `<name>_sub` go2rtc stream. Cameras WITHOUT one (e.g. a
    /// doorbell exposed as a single stream) must NOT be offered a sub URL — otherwise the live
    /// model wastes retries on a 404 `<name>_sub` and collapses to low-quality MJPEG instead of
    /// just playing the full-quality main. Only meaningful once `subStreamsKnown` is true.
    @Published var subStreamCameras: Set<String> = []
    /// True once the go2rtc stream list has loaded at least once, so `subStreamCameras` is
    /// authoritative. Before then, callers assume a sub MAY exist (old behavior) rather than
    /// forcing every camera onto its heavy main stream during the initial load.
    @Published var subStreamsKnown = false
    /// Whether go2rtc HLS live streaming exists on this Frigate. 0.18 removed the nginx route
    /// serving it (live view is WebRTC-only there); 0.17 has it. Probed once per session — until
    /// (and unless) the probe says otherwise, the proven HLS-first pipeline is used. When false,
    /// LiveHLSPlayerView promotes the WebRTC layer from "overlay" to the PRIMARY live renderer.
    @Published var liveHLSAvailable = true
    /// One probe per session (re-armed on sign-out/server switch).
    private var liveHLSProbed = false
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

    /// True when the optional home-network URL (`session.localBaseURL`) is currently reachable
    /// AND confirmed to be this Frigate. Drives which base URL `client` builds. Defaults `false`
    /// (remote) and only flips `true` on a positive, identity-checked probe — so a stuck or
    /// permission-denied probe never blocks the app on an unreachable LAN address; it just stays
    /// on the remote URL. HA-Companion-style local↔remote auto-switching.
    @Published private(set) var onLocalNetwork = false
    /// Validation message for the Settings "Home Network URL" field (nil = no error).
    @Published var localURLError: String?

    /// Watches for network changes (WiFi↔cellular, joining/leaving home) so the local probe
    /// re-runs at the moments that matter, instead of on a wasteful timer.
    private let pathMonitor = NWPathMonitor()
    private var localProbeTask: Task<Void, Never>?
    private var localMonitorStarted = false

    var client: FrigateClient? {
        guard let session else { return nil }
        let base = (onLocalNetwork && session.localBaseURL != nil) ? session.localBaseURL! : session.baseURL
        return FrigateClient(baseURL: base, token: session.token)
    }

    /// Short label for the Settings connection indicator. "Home network" only when a local URL is
    /// configured and currently confirmed reachable; otherwise "Remote".
    var connectionModeLabel: String {
        guard session?.localBaseURL != nil else { return "Remote" }
        return onLocalNetwork ? "Home network" : "Remote"
    }

    // Removed in the nonisolated deinit; removeObserver is thread-safe.
    private nonisolated(unsafe) var quickActionObserver: NSObjectProtocol?

    init() {
        session = keychain.loadSession()
        // Paint the camera wall the instant the app launches: restore the last-known camera list
        // so real tiles render immediately (the network refresh replaces it moments later).
        // Together with the on-disk snapshot cache this means a cold launch shows real cameras
        // with their last-known frames right away instead of an empty/black grid.
        if session != nil {
            cameras = Self.loadPersistedCameras()
        }
        eventStream.onEvent = { [weak self] event in
            self?.handleStreamEvent(event)
        }
        startLocalNetworkMonitor()
        WatchSyncManager.shared.activate()
        // Sweep yesterday's downloaded clips / reel segments out of tmp. iOS only purges tmp
        // opportunistically, so a regular exporter would otherwise accrue gigabytes of
        // clip-*/reel-*/seg-*/dl-* leftovers. Age-gated (>24h) so anything still referenced by
        // an open share sheet from THIS session is never touched.
        Task.detached(priority: .background) {
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory
            let prefixes = ["clip-", "reel-", "seg-", "dl-"]
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            guard let items = try? fm.contentsOfDirectory(
                at: tmp, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { return }
            for item in items where prefixes.contains(where: { item.lastPathComponent.hasPrefix($0) }) {
                let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if modified < cutoff { try? fm.removeItem(at: item) }
            }
        }
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

    // MARK: Camera-list persistence

    /// The last-known camera list is cached in the app group so a cold launch can render the
    /// wall immediately instead of waiting on the network refresh. Versioned so a future model
    /// change can invalidate cleanly.
    private static let savedCamerasKey = "apex.savedCameras.v1"

    private static func persistCameras(_ cameras: [FrigateCamera]) {
        let defaults = UserDefaults(suiteName: ApexAppGroup.identifier)
        if cameras.isEmpty {
            defaults?.removeObject(forKey: savedCamerasKey)
        } else if let data = try? JSONEncoder().encode(cameras) {
            defaults?.set(data, forKey: savedCamerasKey)
        }
    }

    private static func loadPersistedCameras() -> [FrigateCamera] {
        guard let data = UserDefaults(suiteName: ApexAppGroup.identifier)?.data(forKey: savedCamerasKey),
              let cameras = try? JSONDecoder().decode([FrigateCamera].self, from: data) else { return [] }
        return cameras
    }

    /// Mirrors the active Frigate base URL + token into the app group so the
    /// notification service extension can authenticate snapshot/GIF downloads for
    /// remote pushes that don't carry a token (the HA bridge has no user token).
    private func mirrorSessionToAppGroup() {
        let defaults = UserDefaults(suiteName: ApexAppGroup.identifier)
        if let session {
            // Token BEFORE url: every reader (NSE, widgets) reads the URL first, then the token —
            // writing in that same order would let a read land between them and see the NEW url
            // paired with the OLD token (this exact window, however brief). Writing the token
            // first means a reader in the gap sees only the OLD url with the NEW token, which the
            // old server harmlessly rejects — the safer of the two possible mismatches.
            SharedTokenStore.save(session.token)
            defaults?.set(session.baseURL.absoluteString, forKey: "apex.frigateBaseURL")
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
                self?.syncDevicePrefs()
                self?.probeLiveHLSIfNeeded()
                // Fire-and-forget (like the syncs above) so a slow/black-holed relay's house-mode
                // fetch (8s timeout) can't stretch the 15s alert-poll cadence when Frigate is fine.
                Task { [weak self] in await self?.refreshHouseMode() }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    func stopForegroundPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Gate signature this app INSTANCE has already attempted, so the 15s poll doesn't re-POST the
    /// same state repeatedly. Marked optimistically (before the request completes) and rolled back
    /// on failure, so it deliberately does NOT survive relaunch — see `lastConfirmedGate`.
    private var lastSyncedGate: String?

    /// Gate signature the relay has actually ACKed (2xx), PERSISTED in the app group.
    ///
    /// Two separate bugs make this split necessary, and collapsing them back into one variable
    /// reintroduces one or the other:
    ///
    ///  • In-memory only → reset to nil on every cold launch, so the first poll re-POSTed this
    ///    phone's LOCAL snooze over household state: a snooze the other phone had just cleared came
    ///    straight back next time this one was opened.
    ///  • Persisted but written OPTIMISTICALLY → if the POST fails and the app is killed before the
    ///    rollback runs, the stored value permanently claims "synced" and the gate never re-syncs.
    ///    Fail-CLOSED: the relay would keep silencing (or keep alerting) against the user's intent
    ///    with nothing to correct it.
    ///
    /// So: attempt-tracking stays in memory, and only a CONFIRMED result is written here.
    private var lastConfirmedGate: String? {
        get { UserDefaults(suiteName: ApexAppGroup.identifier)?.string(forKey: Self.lastConfirmedGateKey) }
        set {
            let defaults = UserDefaults(suiteName: ApexAppGroup.identifier)
            if let newValue { defaults?.set(newValue, forKey: Self.lastConfirmedGateKey) }
            else { defaults?.removeObject(forKey: Self.lastConfirmedGateKey) }
        }
    }
    private static let lastConfirmedGateKey = "apex.lastConfirmedGate"
    /// When the relay last CONFIRMED a gate POST from this device. Needed alongside the signature
    /// because `adoptClearedHouseholdSnooze` must also know a `/v1/mode` response was issued AFTER
    /// that confirmation — see the race note there.
    private var lastGateConfirmedAt: Double = 0
    /// Last recap schedule we pushed to the relay, so we only POST when it changes.
    private var lastSyncedRecap: String?
    /// Last device-prefs blob signature we pushed, so the 15s foreground poll only POSTs on change.
    private var lastSyncedDevicePrefs: String?

    /// Mirrors the Daily Recap schedule to the relay so the summary fires at the chosen
    /// local time with the app closed. Idempotent — only POSTs when the schedule changes.
    func syncRecapIfChanged() {
        let offset = TimeZone.current.secondsFromGMT()
        let signature = "\(RecapSettings.enabled)|\(RecapSettings.hour)|\(RecapSettings.minute)|\(offset)"
        guard signature != lastSyncedRecap else { return }

        let relayURL = DeviceTokenStore.relayURL
        let pairing = DeviceTokenStore.ensurePairingCode()
        guard !relayURL.isEmpty, !pairing.isEmpty else { return }
        // Mark synced optimistically so a concurrent call de-dups, but roll back on failure so the
        // next foreground poll retries — otherwise a dropped POST leaves the relay permanently stale.
        lastSyncedRecap = signature
        Task {
            do {
                try await RelayClient.syncRecap(
                    relayURL: relayURL, pairingCode: pairing,
                    enabled: RecapSettings.enabled, hour: RecapSettings.hour,
                    minute: RecapSettings.minute, tzOffset: offset
                )
            } catch {
                if lastSyncedRecap == signature { lastSyncedRecap = nil }
            }
        }
    }

    /// Mirrors the current Disarm / Snooze state to the relay so app-closed pushes are
    /// suppressed while disarmed or snoozed — the relay counterpart of the in-app gate.
    /// Cheap and idempotent: only fires when the state actually changes. (Changes made
    /// from Siri/widgets while the app is fully closed sync on the next foreground.)
    func syncRelayGateIfChanged() {
        let disarmed = !ArmStateStore.notificationsActive
        let snoozedUntil = GlobalSnooze.until?.timeIntervalSince1970 ?? 0
        let signature = GateSyncPolicy.signature(disarmed: disarmed, snoozedUntil: snoozedUntil)
        // Skip when this instance already has it in flight, OR when the relay has already
        // confirmed it (the latter survives relaunch, so a cold launch no longer re-imposes a
        // local snooze the other phone cleared). See GateSyncPolicy for why the two differ.
        guard GateSyncPolicy.shouldPost(signature: signature,
                                        inFlight: lastSyncedGate,
                                        confirmed: lastConfirmedGate) else { return }

        let relayURL = DeviceTokenStore.relayURL
        let pairing = DeviceTokenStore.ensurePairingCode()
        guard !relayURL.isEmpty, !pairing.isEmpty else { return }
        // Optimistic mark + rollback-on-failure: the gate mirror is safety-critical (it's what
        // silences pushes while disarmed), so a failed POST must retry, not silently stick.
        // Only the in-memory marker is set here — persisting before the relay confirms would
        // make a POST that failed just before the app was killed look permanently synced.
        lastSyncedGate = signature
        Task {
            do {
                try await RelayClient.syncGate(
                    relayURL: relayURL, pairingCode: pairing,
                    disarmed: disarmed, snoozedUntil: snoozedUntil
                )
                lastConfirmedGate = signature
                lastGateConfirmedAt = Date().timeIntervalSince1970
            } catch {
                if lastSyncedGate == signature { lastSyncedGate = nil }
            }
        }
    }

    /// Sync THIS device's soft notification prefs (per-camera/object/zone mutes, quiet hours,
    /// per-camera snoozes, triggers) to the relay so app-closed pushes are gated per device exactly
    /// as the foreground app. Soft-only — Disarm/Snooze-all stay household via `syncRelayGateIfChanged`.
    /// Fire-and-forget; no-op until pairing + a device token exist. Call on any notification-setting
    /// change and on foreground (foreground heals any drift between the synced blob and reality).
    func syncDevicePrefs() {
        let relayURL = DeviceTokenStore.relayURL
        let pairing = DeviceTokenStore.ensurePairingCode()
        guard !relayURL.isEmpty, !pairing.isEmpty,
              let token = DeviceTokenStore.deviceTokenHex, !token.isEmpty else { return }
        let prefs = notificationPrefs.preferences
        let triggers = triggerStore.triggers
        let deviceName = DeviceTokenStore.deviceName
        // Only POST when something actually changed — this is also called from the 15s foreground
        // poll. Signature covers the prefs, triggers, tz offset (so a DST shift re-syncs), and the
        // device name (so a rename propagates to the per-phone HA entity on the next sync).
        let enc = JSONEncoder()
        let sig = [(try? enc.encode(prefs))?.base64EncodedString(),
                   (try? enc.encode(triggers))?.base64EncodedString(),
                   String(TimeZone.current.secondsFromGMT()),
                   // Include this device's Focus mute so a Focus that started/ended while the app
                   // was closed re-syncs on the next foreground instead of being held back by an
                   // otherwise-unchanged signature.
                   String(Int(FocusSnooze.epochForSync)),
                   deviceName].compactMap { $0 }.joined(separator: "|")
        guard sig != lastSyncedDevicePrefs else { return }
        // Optimistic mark + rollback-on-failure so a dropped POST re-syncs on the next foreground
        // poll instead of leaving per-device mutes out of sync with app-closed delivery.
        lastSyncedDevicePrefs = sig
        Task {
            do {
                try await RelayClient.syncDevicePrefs(
                    relayURL: relayURL, deviceToken: token, pairingCode: pairing,
                    deviceName: deviceName, preferences: prefs, triggers: triggers
                )
            } catch {
                if lastSyncedDevicePrefs == sig { lastSyncedDevicePrefs = nil }
            }
        }
    }

    // MARK: - House mode (Alarmo, via the relay) — arm/disarm from the app

    /// Current house mode as the relay mirrors it from Alarmo: "home" / "away" / "night" / "" unknown.
    /// A partner's app reflects a change here within one 15s poll — no friction, no confirmation.
    @Published var houseMode: String = ""
    /// Who last changed the mode (device name), for display. Empty when unknown.
    @Published var houseModeArmedBy: String = ""
    /// True while a set-mode request is in flight, so the UI can show progress + disable the buttons.
    @Published var houseModeBusy = false
    /// Cameras the CURRENT house mode silences (from the relay). Used to filter the Review/Activity
    /// feeds to match the notification rule — Home shows only Front Driveway + Doorbell, etc.
    @Published var houseModeMutedCameras: [String] = []
    /// The full household per-mode mute matrix (mode → muted cameras) that the House Mode Alerts
    /// editor shows and edits. From the relay: the household's custom map when one was saved, else
    /// the built-in defaults. ONE map for every phone on the pairing code.
    @Published var houseModeMap: [String: [String]] = [:]
    /// True when the household has customized the matrix (vs. built-in defaults).
    @Published var houseModeMapIsCustom = false
    /// Camera roster the relay knows for the matrix (last synced with a save, or the relay's
    /// fallback) — lets the House Mode Alerts editor list EVERY camera (including never-muted
    /// ones) even before the live Frigate camera list has loaded.
    @Published var houseModeCameraRoster: [String] = []
    /// Household notification gate, surfaced so the app can SHOW that alerts are silenced instead
    /// of dropping them invisibly (the "why am I not getting notifications" fix). Epoch; 0 = off.
    @Published var householdSnoozedUntil: Double = 0
    @Published var householdDisarmed = false
    /// Which device silenced the household, and when — surfaced in the banner so "why did my
    /// notifications stop?" answers itself. Empty / 0 when the relay reports no active gate.
    @Published var householdGateBy: String = ""
    @Published var householdGateAt: Double = 0
    /// THIS phone's own Focus mute, mirrored so the banner re-renders when it changes. `FocusSnooze`
    /// is app-group state written by the widget extension, so reading it straight from a view body
    /// wouldn't invalidate anything when a Focus starts or ends. Epoch; 0 = not muted.
    @Published var focusMutedUntil: Double = 0

    /// "Set by Brandon's iPhone at 2:16 PM" for the household-gate banners, or nil when the relay
    /// didn't report attribution (an older relay, or a gate set before 1.16.0) — callers fall back
    /// to their generic copy rather than showing a half-empty sentence. Returns the attribution
    /// alone; each banner appends its own call to action.
    var householdGateAttribution: String? {
        let who = householdGateBy.trimmingCharacters(in: .whitespaces)
        guard !who.isEmpty else { return nil }
        guard householdGateAt > 0 else { return "Set by \(who)" }
        let when = Date(timeIntervalSince1970: householdGateAt)
            .formatted(date: .omitted, time: .shortened)
        return "Set by \(who) at \(when)"
    }
    /// Set when the "Snooze Alerts" Home Screen quick action fires, so the UI can ask "are you
    /// sure?" instead of instantly silencing the WHOLE HOUSEHOLD's alerts for an hour. That quick
    /// action is the FIRST, always-present item in a long-press menu that's trivially easy to land
    /// on by accident — an unintended tap must not read as "I just opened the app" while quietly
    /// disarming notifications. Confirmed via `confirmHouseholdSnooze()`.
    @Published var pendingSnoozeConfirmation = false

    /// Applies the household-wide 1-hour snooze the "Snooze Alerts" quick action requested, once
    /// the user has explicitly confirmed it (see `pendingSnoozeConfirmation`).
    func confirmHouseholdSnooze() {
        let until = Date().addingTimeInterval(60 * 60)
        GlobalSnooze.snooze(until: until)
        Task { await RelayGate.sync(snoozedUntil: until.timeIntervalSince1970) }
    }
    /// User escape hatch: when true, the feeds ignore the house-mode filter and show every camera.
    /// @Published (not @AppStorage — that doesn't emit objectWillChange from an ObservableObject, so
    /// the feeds wouldn't re-filter on toggle); persisted by hand so the choice survives relaunch.
    @Published var showAllCamerasInFeeds: Bool = SharedHouseMode.showAllCameras {
        didSet {
            // Same app-group key as before; `SharedHouseMode` now owns its spelling so the widget
            // process reads exactly what the app writes.
            SharedHouseMode.showAllCameras = showAllCamerasInFeeds
        }
    }

    /// Whether a camera's activity should surface in the Review/Activity feeds right now: hidden only
    /// when the current mode affirmatively mutes it AND the user hasn't chosen to show all. FAIL-OPEN:
    /// unknown mode / empty mute list / a camera not in the list all show (mirrors the relay gate).
    func cameraVisibleInFeeds(_ camera: String) -> Bool {
        HouseModeVisibility.cameraVisible(camera, mutedCameras: houseModeMutedCameras, showAll: showAllCamerasInFeeds)
    }

    /// Pull the current house mode from the relay so the app reflects the real Alarmo state. Called
    /// on the 15s foreground poll (and right after a change) — this is how a partner's app follows.
    func refreshHouseMode() async {
        let relayURL = DeviceTokenStore.relayURL
        guard !relayURL.isEmpty else { return }
        let pairing = DeviceTokenStore.ensurePairingCode()
        // Stamped BEFORE the request so `adoptClearedHouseholdSnooze` can tell a response that
        // reflects our latest gate POST from one that was already in flight when we sent it.
        let fetchStartedAt = Date().timeIntervalSince1970
        guard let status = await RelayClient.getMode(relayURL: relayURL, pairingCode: pairing) else { return }
        let modeChanged = status.mode != houseMode
        if modeChanged { houseMode = status.mode }
        let by = status.armed_by?.by ?? ""
        if by != houseModeArmedBy { houseModeArmedBy = by }
        let mutes = status.mutes ?? []
        if mutes != houseModeMutedCameras { houseModeMutedCameras = mutes }
        let map = status.map ?? [:]
        if map != houseModeMap { houseModeMap = map }
        let custom = status.map_custom ?? false
        if custom != houseModeMapIsCustom { houseModeMapIsCustom = custom }
        let roster = status.cameras ?? []
        if roster != houseModeCameraRoster { houseModeCameraRoster = roster }
        // Household gate visibility: only meaningful when the relay recognized our pairing code
        // (fields absent otherwise). An active snooze/disarm surfaces as a banner, never silently.
        let snoozed = status.snoozed_until ?? 0
        if snoozed != householdSnoozedUntil { householdSnoozedUntil = snoozed }
        let disarmed = status.disarmed ?? false
        if disarmed != householdDisarmed { householdDisarmed = disarmed }
        // Attribution for the banner — WHO silenced the house and when. Without this, "why did
        // notifications stop?" had no answer short of reading the relay by hand.
        let gateBy = status.gate_by ?? ""
        if gateBy != householdGateBy { householdGateBy = gateBy }
        let gateAt = status.gate_at ?? 0
        if gateAt != householdGateAt { householdGateAt = gateAt }
        adoptClearedHouseholdSnooze(relaySnoozedUntil: snoozed, fetchStartedAt: fetchStartedAt)
        // Pick up a Focus that started or ended while the app was closed (the filter runs in the
        // widget process, so nothing here observes it directly).
        let focus = FocusSnooze.epochForSync
        if focus != focusMutedUntil { focusMutedUntil = focus }
        // Mirror to the app group so the Lock Screen widgets + Control Center controls can show it,
        // and refresh those surfaces the moment the mode actually changes.
        SharedHouseMode.mode = status.mode
        SharedHouseMode.armedBy = by
        // The mute list has to cross into the app group too, or the widget/Watch/Siri feeds — which
        // are written from extension processes with no access to AppState — keep listing cameras
        // this mode has silenced, while the Review tab and the relay's push gate both suppress them.
        // Stamped with the mode it was read for — a list left over from a different mode must not
        // filter the widget feed (see SharedHouseMode.mutedCameras).
        SharedHouseMode.setMutedCameras(mutes, for: status.mode)
        if modeChanged { ApexSurfaceRefresh.reload() }
    }

    /// Adopt a household snooze that someone else cleared, so tapping "resume" on ONE phone
    /// actually resumes alerts on every phone.
    ///
    /// Without this, the other phone kept a local `GlobalSnooze` the relay no longer had: its own
    /// delivery gate stayed muted, and it would re-POST that stale snooze and re-silence the
    /// household on its next cold launch.
    ///
    /// Guarded against two races, both of which would cancel a snooze the user just set:
    ///
    /// 1. The snooze must be one the relay has ACKed — `lastConfirmedGate` (written only on a 2xx)
    ///    matching our current local state. A snooze that never reached the relay is absent there
    ///    because it wasn't written yet, not because someone cleared it.
    /// 2. A matching signature still isn't enough: this read must also have STARTED after that
    ///    confirmation. Otherwise a `/v1/mode` response already in flight when we sent the snooze
    ///    reports the pre-snooze state, and adopting it would undo the user's own action. Both the
    ///    gate POST and the mode fetch are kicked off from the same 15s poll tick, so the window
    ///    between them is real, not theoretical.
    private func adoptClearedHouseholdSnooze(relaySnoozedUntil: Double, fetchStartedAt: Double) {
        let disarmed = !ArmStateStore.notificationsActive
        let localSnooze = GlobalSnooze.until
        let currentSignature = GateSyncPolicy.signature(
            disarmed: disarmed, snoozedUntil: localSnooze?.timeIntervalSince1970 ?? 0)
        guard GateSyncPolicy.shouldAdoptClear(
            relaySnoozedUntil: relaySnoozedUntil,
            hasLocalSnooze: localSnooze != nil,
            currentSignature: currentSignature,
            confirmed: lastConfirmedGate,
            confirmedAt: lastGateConfirmedAt,
            fetchStartedAt: fetchStartedAt
        ) else { return }
        GlobalSnooze.clear()
        let cleared = GateSyncPolicy.signature(disarmed: disarmed, snoozedUntil: 0)
        lastSyncedGate = cleared
        lastConfirmedGate = cleared   // this IS the relay's current state — we just read it
    }

    /// Save the household per-mode alert matrix (from the House Mode Alerts editor). Household-wide:
    /// the relay stores ONE map per pairing code, the bridge mirrors it into Frigate's per-camera
    /// alert switches, and every phone (and HA) follows. Refreshes local state on success.
    func saveHouseModeMap(_ mutes: [String: [String]], reset: Bool = false) async throws {
        let relayURL = DeviceTokenStore.relayURL
        let pairing = DeviceTokenStore.ensurePairingCode()
        guard !relayURL.isEmpty, !pairing.isEmpty else { throw RelayClient.RelayError.invalidURL }
        // Prefer the live Frigate list; fall back to the relay's stored roster so a save made
        // before cameras load never posts an empty roster (which would shrink the editor's rows).
        let roster = cameras.isEmpty ? houseModeCameraRoster : cameras.map(\.name)
        try await RelayClient.setModeMap(
            relayURL: relayURL, pairingCode: pairing, mutes: mutes,
            cameras: roster, by: DeviceTokenStore.deviceName, reset: reset
        )
        await refreshHouseMode()
    }

    /// Clear the household snooze/disarm gate so notifications resume for EVERYONE — the action
    /// behind the "notifications snoozed" banner. Clears the local mirrors too so the next
    /// foreground gate sync doesn't re-impose a stale local snooze.
    func resumeHouseholdNotifications() async {
        GlobalSnooze.clear()
        if ArmStateStore.mode == .disarmed { ArmStateStore.mode = .away }
        // Force the next syncRelayGateIfChanged through: clear BOTH the in-flight marker and the
        // persisted confirmation, or the resume would be skipped as "already synced".
        lastSyncedGate = ""
        lastConfirmedGate = ""
        await RelayGate.syncCurrent()
        syncRelayGateIfChanged()
        await refreshHouseMode()
    }

    /// Request an arm/disarm. Arming ("away"/"night") rides the pairing code; disarming ("home")
    /// must carry the Alarmo code (validated by Alarmo). Returns true once the house actually
    /// reaches `mode`. Throws on a relay-level rejection (e.g. a code-less disarm).
    ///
    /// The round trip is real work — relay → bridge (≤1s poll) → MQTT → HA → Alarmo → publish-back
    /// → relay → us — so ~3–6s, not instant. We poll for convergence up to ~12s instead of checking
    /// once too early (which would flag a *successful* disarm as failed). A wrong disarm code never
    /// converges → the caller shows the error; a correct one lands within a couple of polls.
    @discardableResult
    func requestHouseMode(_ mode: String, code: String = "") async throws -> Bool {
        let relayURL = DeviceTokenStore.relayURL
        let pairing = DeviceTokenStore.ensurePairingCode()
        let token = DeviceTokenStore.deviceTokenHex ?? ""
        guard !relayURL.isEmpty, !pairing.isEmpty else { throw RelayClient.RelayError.invalidURL }
        houseModeBusy = true
        defer { houseModeBusy = false }
        try await RelayClient.setMode(relayURL: relayURL, deviceToken: token,
                                      pairingCode: pairing, mode: mode, code: code)
        // Lock Screen / Dynamic Island arm banner: countdown on Away arm, "Armed" for Night,
        // cleared on disarm. 60s matches the Alarmo Away exit delay (Night has none → instant).
        if #available(iOS 16.1, *) {
            if mode == "home" {
                HouseModeActivityController.disarm()
            } else {
                HouseModeActivityController.startArm(
                    mode: mode, by: DeviceTokenStore.deviceName, exitDelay: mode == "away" ? 60 : 0)
            }
        }
        for _ in 0..<9 {   // ~1.3s × 9 ≈ 12s
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            await refreshHouseMode()
            if houseMode == mode { return true }
        }
        return false
    }

    /// Lightweight refresh of just the things that need to feel live: reviews + events.
    func refreshAlerts(retryOnAuthFailure: Bool = true) async {
        guard let client else { return }
        do {
            async let nextReviews = client.reviews(limit: 100, reviewed: false)
            async let nextEvents = client.events(limit: 100)
            let r = try await nextReviews
            let e = try await nextEvents
            // Reassign only when something actually changed — but compare CONTENT
            // (id + severity + objects + sub-labels), not just ids, so a review that
            // gains a recognized sub-label (e.g. "Amazon") still updates the list,
            // the widget, and the lock screen.
            let visible = visibleReviews(r)
            let reviewsChanged = reviewSignature(visible) != reviewSignature(reviews)
            if reviewsChanged { reviews = visible }
            // Server list is authoritative — drop any staged WS copy so a pending
            // flush can't overwrite this fresher data 250ms later.
            if eventSignature(e) != eventSignature(events) { pendingEvents = nil; events = e; SpotlightIndexer.index(e) }
            if reviewsChanged { cacheLatestAlertForWidget() }
            // Badge = the un-reviewed ALERTS currently in the list, so it always matches
            // what you see and clearing them drops it to zero — not the entire retained
            // server history (which could be thousands of never-reviewed old alerts).
            // Guard both assignments: @Published fires objectWillChange (re-rendering every
            // view holding AppState) even when re-assigning an identical value, and
            // unreviewedCount's didSet also writes the app-group plist + a setBadgeCount system
            // call. On the 15s foreground poll that was churning the whole app every tick.
            // Count only cameras the current house mode shows in the feed, so the tab badge
            // matches the Review list — a muted-camera alert can't bump a badge you can't clear.
            let newUnreviewed = visible.filter { $0.severity == "alert" && cameraVisibleInFeeds($0.camera) }.count
            if newUnreviewed != unreviewedCount { unreviewedCount = newUnreviewed }
            if !isReachable { isReachable = true }
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
        // Paging the backlog plus the chunked POSTs is seconds of awaits; pin the local wipe to
        // THIS server so a sign-out or switch part-way through can't empty the NEW server's
        // freshly-loaded queue and zero the badge + widgets on it.
        let gen = serverGeneration
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
                if serverGeneration == gen { reviews.removeAll() }
                return
            }
            // Mark in chunks so a huge backlog doesn't blow the request body.
            for start in stride(from: 0, to: ids.count, by: 500) {
                let slice = Array(ids[start..<min(start + 500, ids.count)])
                try await client.markReviewsViewed(ids: slice)
            }
            // Server-side marks already landed; skipping the local wipe on a stale generation is
            // always the safe direction — the next poll reconciles.
            guard serverGeneration == gen else { return }
            locallyViewedIDs.formUnion(ids)
            reviews.removeAll()
            unreviewedCount = 0
            cacheLatestAlertForWidget()   // clears the widgets too
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
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
        // Apply the SAME house-mode filter the Review tab renders with. `reviews` is filtered only
        // for already-viewed items (see visibleReviews), so without this the widget hero, the
        // widget feed, the Watch list and Siri's "latest alert" all surfaced cameras the current
        // mode silences — while the Review tab hid them and the relay suppressed their pushes.
        let recent = Array(reviews.filter { cameraVisibleInFeeds($0.camera) }.prefix(8))
        // Nothing left → write "all clear" and reload so the widgets CLEAR (they used to keep
        // showing the last alert because this bailed early on an empty list).
        guard !recent.isEmpty else {
            SharedSnapshotStore.saveRecentAlerts([], heroImageData: nil)
            WidgetCenter.shared.reloadAllTimelines()
            WatchSyncManager.shared.push(alerts: [], heroJPEG: nil)
            return
        }

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
            // A dropped/reconnecting WebSocket never gets to see the in-flight detection's `.end`
            // event, so without this a stale "person detected" box (and the Dynamic Island aura it
            // drives) sticks around indefinitely — surviving background/foreground and network
            // blips — until some unrelated future detection on the same camera happens to end.
            pendingDetections.removeAll()
            if !liveDetections.isEmpty { liveDetections = [:] }
        case .stats(let s):
            stats = s
        case .event(let item, let change):
            upsertEvent(item)
            updateLiveDetection(item, change: change)
        case .review(let item, let change):
            handleReview(item, change: change)
        case .controlState(let camera, let feature, let on):
            applyControlState(camera: camera, feature: feature, on: on)
        }
    }

    /// Live per-camera feature state, kept current from Frigate's `<camera>/<feature>/state`
    /// WebSocket topics (Frigate sends the retained current values on connect, then updates on
    /// every change). This is the SOURCE OF TRUTH for the Controls sheet — `/api/config` only
    /// reflects the config file, not the running toggles.
    @Published var cameraControlStates: [String: CameraControlState] = [:]

    private func applyControlState(camera: String, feature: String, on: Bool) {
        var state = cameraControlStates[camera] ?? CameraControlState()
        switch feature {
        case "detect": state.detect = on
        case "recordings": state.recordings = on
        case "snapshots": state.snapshots = on
        case "audio": state.audio = on
        case "motion": state.motion = on
        default: return
        }
        if cameraControlStates[camera] != state { cameraControlStates[camera] = state }
    }

    /// Toggle a runtime camera feature LIVE over the WebSocket (the only thing Frigate applies
    /// without a restart). Returns whether the command reached a live socket.
    ///
    /// The optimistic local write is applied ONLY on a successful send. Frigate 0.18 does not
    /// relay `<camera>/<feature>/state`, so nothing ever corrects an optimistic value — writing it
    /// after a dropped send (socket down / reconnect backoff) left the toggle showing "Recording
    /// on" for a camera that was never told to record.
    @discardableResult
    func setCameraControl(camera: String, feature: CameraFeature, enabled: Bool) -> Bool {
        guard eventStream.send(topic: "\(camera)/\(feature.rawValue)/set",
                               payload: enabled ? "ON" : "OFF") else { return false }
        applyControlState(camera: camera, feature: feature.rawValue, on: enabled)
        return true
    }

    private func updateLiveDetection(_ item: FrigateEvent, change: ChangeType) {
        // Frigate 0.18's WebSocket tracked-object payload has NO top-level `width`/`height` keys
        // (measured: 81 consecutive live `events` frames, zero occurrences), so `item.frameWidth`
        // and `item.frameHeight` are always nil and this guard used to reject every detection —
        // the overlay and the Dynamic Island aura could never see a box at all. `box` is already
        // in the camera's DETECT-frame pixels, which `/api/config` gives us per camera, so fall
        // back to that. Prefer the event's own size whenever a server does send one.
        let detectFrame = cameras.first { $0.name == item.camera }
        guard let normBox = DetectionBox.normalized(
            box: item.box,
            frameWidth: item.frameWidth ?? detectFrame?.width.map(Double.init),
            frameHeight: item.frameHeight ?? detectFrame?.height.map(Double.init)
        ) else {
            if change == .end {
                pendingDetections[item.camera]?.removeAll { $0.id == item.id }
                if pendingDetections[item.camera]?.isEmpty == true { pendingDetections.removeValue(forKey: item.camera) }
                scheduleDetectionFlush()
            }
            return
        }
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

    /// Stage the event and publish at most ~4 Hz. Updates to a known event replace it
    /// in place (no reshuffle-to-top on every box move); only genuinely new events
    /// insert at the front. Publishing per raw WS frame re-rendered every AppState
    /// observer — the whole app — at several Hz during motion (the same storm the
    /// detections coalescer fixed, on the other `@Published` variable).
    private func upsertEvent(_ item: FrigateEvent) {
        var list = pendingEvents ?? events
        if let idx = list.firstIndex(where: { $0.id == item.id }) {
            list[idx] = item
        } else {
            list.insert(item, at: 0)
            if list.count > 100 { list = Array(list.prefix(100)) }
        }
        pendingEvents = list
        scheduleEventFlush()
    }

    private func scheduleEventFlush() {
        guard !eventFlushScheduled else { return }
        eventFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            self.eventFlushScheduled = false
            if let pending = self.pendingEvents {
                self.pendingEvents = nil
                if pending != self.events { self.events = pending }
            }
        }
    }

    private func handleReview(_ item: FrigateReviewItem, change: ChangeType) {
        guard !locallyViewedIDs.contains(item.id) else { return }
        reviews.removeAll { $0.id == item.id }
        // Keep the Review tab + app-icon badge instant on EVERY WebSocket-delivered
        // change — including the removal-only paths (review ended, marked reviewed
        // elsewhere), which used to leave the badge stale for up to 15s of poller lag.
        defer { unreviewedCount = reviews.filter { $0.severity == "alert" && cameraVisibleInFeeds($0.camera) }.count }

        // Already handled on the server (e.g. marked reviewed elsewhere) → keep it gone.
        if item.hasBeenReviewed == true { return }

        if change == .end {
            // Only dismiss the Live Activity for alert reviews — and only THIS camera's.
            // Ending them all tore down another camera's still-active incident banner
            // whenever incidents overlapped.
            if item.severity == "alert" { IncidentActivityController.end(camera: item.camera) }
            // The incident ENDED but is still unreviewed — it belongs in the queue. Removing
            // it made the row + badge vanish, then flap back on the next 15s poll (which
            // fetches reviewed:false and re-adds it).
            reviews.insert(item, at: 0)
            if reviews.count > 100 { reviews = Array(reviews.prefix(100)) }
            return
        }

        reviews.insert(item, at: 0)
        if reviews.count > 100 { reviews = Array(reviews.prefix(100)) }

        let label = item.data?.objects?.first ?? "object"
        let zones = item.data?.zones ?? []

        // Live Activity: when instant push is active the RELAY starts/updates the incident
        // Live Activity (so it appears even with the app closed, and we don't double it).
        // Without a confirmed relay, the app drives it itself as the in-app fallback —
        // but it must respect the user's mutes (Disarm, snoozes, per-camera/object/zone,
        // quiet hours) exactly like every other alert surface. `wouldDeliver` is the
        // side-effect-free check: no cooldown consumed, so incident UPDATES keep flowing.
        if item.severity == "alert", !DeviceTokenStore.hasRemotePush,
           notificationPrefs.wouldDeliver(
               camera: item.camera, label: label, zones: zones,
               score: 0, triggers: triggerStore.triggers
           ) {
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

        // Dedup BEFORE the cooldown check: `shouldDeliver` stamps the cooldown clock as
        // a side effect, so running it on already-seen incident updates kept refreshing
        // the cooldown and could starve a genuinely NEW alert on the same camera for the
        // whole incident.
        guard LastSeenStore.isNew(item.id) else { return }
        guard notificationPrefs.shouldDeliver(
            camera: item.camera, label: label, zones: zones,
            score: 0, triggers: triggerStore.triggers
        ) else { return }
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
            reviewID: item.id,
            // Frigate's AI rating, when this review already carries a summary. Most won't at
            // banner time (the summary is generated after the review ends), and .routine is the
            // right default — an unrated alert must look normal, never alarming.
            level: item.trustedThreatLevel ?? .routine
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

    // MARK: - Home-network fast path (local ↔ remote auto-switch)

    /// Starts the NWPathMonitor once. Every network change (WiFi↔cellular, joining/leaving the
    /// home LAN) schedules a debounced probe, so the app upgrades to the local URL the moment
    /// home is reachable and drops back to remote the moment it isn't — no polling.
    private func startLocalNetworkMonitor() {
        guard !localMonitorStarted else { return }
        localMonitorStarted = true
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.scheduleLocalProbe(debounce: 0.7) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.brandontoth.apexsight.pathmonitor"))
    }

    /// Coalesces bursty path updates (a WiFi↔cellular handoff fires several in a row) into a
    /// single probe. Callable directly with no debounce for an immediate check (foreground).
    func scheduleLocalProbe(debounce: TimeInterval = 0) {
        localProbeTask?.cancel()
        localProbeTask = Task { [weak self] in
            if debounce > 0 {
                try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
                if Task.isCancelled { return }
            }
            await self?.evaluateLocalNetwork()
        }
    }

    /// Probes now and again after short delays. Used right after the user saves a local URL: the
    /// very first probe RAISES the iOS Local Network permission prompt and fails while it's up, so
    /// a single probe would leave the app stuck on Remote until the next foreground. Re-probing at
    /// ~+2s and ~+6s picks up the just-granted permission and flips to the fast path immediately.
    private func burstLocalProbe() {
        localProbeTask?.cancel()
        localProbeTask = Task { [weak self] in
            await self?.evaluateLocalNetwork()
            for delay: UInt64 in [2_000_000_000, 4_000_000_000] {
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled { return }
                await self?.evaluateLocalNetwork()
            }
        }
    }

    /// Probes the configured local URL and flips `onLocalNetwork`. Default-remote, confirm-to-local:
    /// only a positive, identity-checked probe turns the fast path on; any failure (unreachable,
    /// permission denied, foreign device) leaves us on remote. The snapshot wall re-reads `client`
    /// on its refresh loop and follows the swapped base URL within a few seconds — no manual
    /// reconnect needed — and a flip triggers a `refresh()` so the change feels immediate.
    private func evaluateLocalNetwork() async {
        guard let session, let local = session.localBaseURL else {
            if onLocalNetwork { onLocalNetwork = false }
            return
        }
        let probe = FrigateClient(baseURL: local, token: session.token)
        // Identity-check against this server's known cameras so a *different* Frigate sharing the
        // same LAN IP on a foreign network can't be mistaken for home (many home Frigates don't
        // enforce auth on the LAN, so status alone isn't proof of identity).
        let expected = Set(cameras.map(\.name))
        var reachable = await probe.probeReachableFrigate(expectedCameras: expected)
        // A cancelled probe (a newer path update superseded this one) returns false from the
        // URLSession cancellation — bail without touching state so we don't demote home→tunnel on
        // a supersession. The newer probe owns the decision.
        if Task.isCancelled { return }
        // One quick retry before *demoting* home→remote, so a single transient blip (a roaming
        // handoff, a momentary drop) doesn't bounce everyone onto the slower tunnel.
        if !reachable && onLocalNetwork {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            reachable = await probe.probeReachableFrigate(expectedCameras: expected)
            if Task.isCancelled { return }
        }
        let changed = onLocalNetwork != reachable
        onLocalNetwork = reachable
        // Repaint promptly against the new base URL. Snapshots would follow on their own loop
        // within a few seconds; this makes the switch feel instant.
        if changed { await refresh() }
    }

    /// Sets (or clears, when empty) the optional home-network URL for the current server, persists
    /// it to the Keychain, and immediately probes — so the iOS Local Network permission prompt
    /// surfaces here, in context, right after the user saves, rather than at some random later
    /// moment. Same server ⇒ same JWT, so no re-auth is needed; only the base URL changes.
    func setLocalURL(_ raw: String) {
        guard let session else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let local: URL?
        if trimmed.isEmpty {
            local = nil
        } else if let url = try? FrigateSession.normalizedBaseURL(trimmed) {
            local = url
        } else {
            localURLError = "That address doesn't look right — include the LAN IP, e.g. 192.168.1.204:5000."
            return
        }
        localURLError = nil
        let next = FrigateSession(
            baseURL: session.baseURL,
            username: session.username,
            token: session.token,
            password: session.password,
            localBaseURL: local
        )
        keychain.save(session: next)
        self.session = next
        if local == nil {
            onLocalNetwork = false
        } else {
            burstLocalProbe()   // in-context permission prompt + re-probe once it's granted
        }
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
            errorMessage = Self.userFacingMessage(for: error)
        }
        isLoading = false
    }

    /// Turns a raw error into something actionable, so the user can tell a wrong password apart
    /// from an unreachable server instead of seeing a status code. Any error the mapping doesn't
    /// recognise falls through to `error.localizedDescription`, i.e. the old string.
    ///
    /// Named for sign-in originally and wired there only, which left every POST-login surface —
    /// the Cameras error card, System Health, mark-reviewed — showing Foundation's developer-shaped
    /// copy ("A server with the specified hostname could not be found.") for errors this already
    /// has good words for.
    static func userFacingMessage(for error: Error) -> String {
        // Single funnel for everything the user is ever shown as an error, so the black box records
        // exactly what they saw — without a log call having to be sprinkled at each call site.
        DiagnosticLog.shared.error("app", error)
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
        let gen = serverGeneration
        let task = Task { [weak self] () -> Bool in
            do {
                // Log in against the remote URL — it's reachable everywhere (via the tunnel),
                // so a token refresh works even when away from home / before the local probe.
                let client = FrigateClient(baseURL: session.baseURL)
                let token = try await client.login(username: session.username, password: password)
                // A sign-out or server switch during the login round-trip bumps serverGeneration and
                // nils the session — don't let a late-completing reauth resurrect it (or rewrite the
                // just-cleared keychain). Cancellation is cooperative, so guard the writes explicitly.
                guard let self, self.serverGeneration == gen else { return false }
                let next = FrigateSession(
                    baseURL: session.baseURL,
                    username: session.username,
                    token: token,
                    password: password,
                    localBaseURL: session.localBaseURL
                )
                self.keychain.save(session: next)
                self.session = next
                return true
            } catch {
                return false
            }
        }
        reauthTask = task
        let result = await task.value
        // Only clear if a server switch/sign-out hasn't installed a newer reauth in the
        // meantime — otherwise a stale reauth resuming here would nil out a live task and
        // break the coalescing that keeps concurrent 401s to a single login (mirrors refreshTask).
        if serverGeneration == gen { reauthTask = nil }
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

    /// One-shot per session: detect whether go2rtc HLS live exists on this Frigate (0.18 removed
    /// it — live view is WebRTC-primary there). Runs from the 15s poll (which always runs) rather
    /// than the full refresh (which is skipped when a persisted camera wall exists at launch).
    func probeLiveHLSIfNeeded() {
        guard !liveHLSProbed, let client, let cam = cameras.first?.name else { return }
        liveHLSProbed = true
        // Pin the verdict to THIS server: a switch/sign-out mid-probe bumps serverGeneration, and
        // without this guard the old server's HLS decision could land on the new one.
        let gen = serverGeneration
        Task { [weak self] in
            let probed = await client.probeLiveHLS(camera: cam)
            let verdict = probed.map { $0 ? "available (0.17 pipeline)" : "ABSENT (0.18 → WebRTC-primary)" }
                ?? "inconclusive — will re-probe"
            FputsLog.log("[live] HLS probe (\(cam)) → \(verdict)")
            await MainActor.run {
                guard let self, self.serverGeneration == gen else { return }
                // Only a completed round-trip latches. An inconclusive probe (8s timeout, network
                // drop) leaves liveHLSAvailable at its fail-open default and re-arms the flag so
                // the next 15s poll asks again — otherwise a single timeout pinned the whole
                // session to a pipeline that 404s on 0.18, and every wall tile sat out its
                // fallback timer before dropping to low-res MJPEG with no way back but a relaunch.
                guard let available = probed else { self.liveHLSProbed = false; return }
                if available != self.liveHLSAvailable { self.liveHLSAvailable = available }
            }
        }
    }

    private func refresh(retryOnAuthFailure: Bool) async {
        guard let client else { return }
        // Pin every publish below to THIS server. Cancelling an `async let` child that has
        // ALREADY COMPLETED does not make `try await` throw, and the later awaits are all
        // `try?`, so a sign-out / server switch landing mid-refresh would otherwise let the old
        // server's cameras, events and reviews be published — and persisted — over the cleared
        // state. (Same pattern as reauthenticate() and probeLiveHLSIfNeeded().)
        let gen = serverGeneration
        isLoading = true
        errorMessage = nil
        do {
            async let nextCameras = client.cameras()
            async let nextEvents = client.events(limit: 100)
            async let nextReviews = client.reviews(limit: 100, reviewed: false)
            async let nextLabels = client.labels()
            async let nextSubLabels = client.subLabels()
            async let nextStreams = client.go2rtcStreams()
            // NOTE: stats + logs are intentionally NOT fetched here. /api/logs/frigate is a heavy
            // text blob and both are read only by SystemHealthView (Settings), so refresh() — which
            // runs on every launch / foreground / poll — must not pay for them. Stats stay fresh via
            // the live WebSocket; SystemHealthView fetches both itself via loadSystemHealth().

            let loadedCameras = try await nextCameras
            guard serverGeneration == gen else { isLoading = false; return }
            cameras = loadedCameras
            Self.persistCameras(loadedCameras)
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
            // Await FIRST, then clear + assign in one synchronous block: a WS frame arriving
            // during the await re-stages pendingEvents from the OLD list, and a nil-before-
            // await ordering let that stale copy flush over the fresh server list 250ms later.
            let fetchedEvents = (try? await nextEvents) ?? events
            guard serverGeneration == gen else { isLoading = false; return }
            pendingEvents = nil  // full refresh is authoritative over any staged WS copy
            events = fetchedEvents
            // Await the rest FIRST, then publish in one block behind a single generation check —
            // a switch/sign-out landing on any of these `try?` awaits must not get a half-updated
            // AppState carrying the previous server's reviews and stream capabilities.
            let fetchedReviews = try? await nextReviews
            let fetchedLabels = try? await nextLabels
            let fetchedSubLabels = try? await nextSubLabels
            let streams = (try? await nextStreams) ?? [:]
            guard serverGeneration == gen else { isLoading = false; return }
            if let fetchedReviews {
                reviews = visibleReviews(fetchedReviews)
            }
            labels = fetchedLabels ?? labels
            subLabels = fetchedSubLabels ?? subLabels

            hasBirdseye = streams["birdseye"] != nil
            twoWayCameras = Set(streams.keys.filter { $0.hasSuffix("_twoway") }
                .map { String($0.dropLast("_twoway".count)) })
            subStreamCameras = Set(streams.keys.filter { $0.hasSuffix("_sub") }
                .map { String($0.dropLast("_sub".count)) })
            subStreamsKnown = true
            probeLiveHLSIfNeeded()
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
                errorMessage = Self.userFacingMessage(for: error)
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
        // Re-arm the one-shot HLS-live probe. A different (or absent) server may have a different
        // verdict, and unlike the sub-stream flags — which refresh() unconditionally reassigns —
        // refresh() never overwrites liveHLSAvailable, so without this the FIRST server's HLS
        // decision would stick for the whole process and pin every wall tile to the wrong live
        // pipeline (dead HLS on a 0.18 server, or WebRTC-primary on a 0.17 one) until relaunch.
        liveHLSProbed = false
        liveHLSAvailable = true
    }

    func switchTo(session: FrigateSession) {
        stopRealtime()
        stopForegroundPolling()
        cancelInFlightServerWork()
        locallyViewedIDs.removeAll()
        // New server ⇒ re-evaluate its (possibly different / absent) local URL from scratch.
        onLocalNetwork = false
        StreamPrewarmer.shared.stopAll()
        self.session = session
        keychain.save(session: session)
        scheduleLocalProbe()
        cameras = []
        // Drop the previous server's cached camera list so the next cold launch can't briefly
        // show its cameras before this server's refresh lands.
        Self.persistCameras([])
        pendingEvents = nil
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
        onLocalNetwork = false
        StreamPrewarmer.shared.stopAll()
        // Clear the Watch so it doesn't keep showing the last household's alerts after sign-out.
        WatchSyncManager.shared.push(alerts: [], heroJPEG: nil)
        session = nil
        cameras = []
        Self.persistCameras([])
        pendingEvents = nil
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
        // Only decrement for alerts that actually count toward the badge — i.e. from a camera the
        // current house mode shows. Otherwise the optimistic decrement drifts the badge negative-ish
        // against the house-mode-filtered recompute below.
        if review.severity == "alert", cameraVisibleInFeeds(review.camera) {
            unreviewedCount = max(0, unreviewedCount - 1)
        }
        await markReviewViewed(id: review.id)
    }

    func markReviewViewed(id: String) async {
        guard let client else { return }
        do {
            try await client.markReviewsViewed(ids: [id])
            locallyViewedIDs.insert(id)
            reviews.removeAll { $0.id == id }
            // Badge counts only alerts from cameras the current house mode surfaces — keep this
            // recompute in lockstep with the other badge sites (search for cameraVisibleInFeeds).
            unreviewedCount = reviews.filter { $0.severity == "alert" && cameraVisibleInFeeds($0.camera) }.count
            // Rewrite + reload the widgets so a reviewed alert clears there too, not just in-app.
            cacheLatestAlertForWidget()
        } catch {
            errorMessage = Self.userFacingMessage(for: error)
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
        case "recap", "activity":
            // The Daily Recap push carries apex://recap — land on the Activity feed (the day's
            // events) instead of dead-ending because there was no matching handler.
            deepLink = .activity
        case "house":
            deepLink = .house
        case "doorbell":
            deepLink = .doorbell
        case "latest":
            // Home Screen quick action / Control Center: jump to the most recent alert.
            if let newest = reviews.first {
                deepLink = .review(newest.id)
            } else {
                // Cold launch — reviews aren't fetched yet, so don't dead-end on the camera wall.
                // Load them, then open the newest alert; fall back to the Activity feed if there
                // genuinely are none (still an alert-relevant surface, unlike the wall).
                Task { [weak self] in
                    guard let self else { return }
                    if self.reviews.isEmpty { await self.refresh() }
                    self.deepLink = self.reviews.first.map { .review($0.id) } ?? .activity
                }
            }
        case "snooze":
            // The Home Screen "Snooze Alerts" quick action is the first, always-present item in
            // a long-press menu — an accidental long-press-and-release lands on it easily, and
            // applying an instant, silent, HOUSEHOLD-wide alert snooze from that would read as
            // "notifications got snoozed just from opening the app." Ask first; the actual snooze
            // (+ relay mirror) happens in `confirmHouseholdSnooze()` once the user taps through.
            pendingSnoozeConfirmation = true
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


/// Unbuffered stderr logging (mirrors RealtimeVideoController.rtLog) — `print()` can be swallowed
/// depending on how the process was launched; stderr always reaches the console/log capture.
enum FputsLog {
    static func log(_ message: String) {
        #if DEBUG
        fputs(message + "\n", stderr)
        #endif
    }
}
