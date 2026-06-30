import AVKit
import AVFoundation
import SwiftUI
import UIKit

// MARK: - Stream rules

enum LiveStreamRules {
    /// Returns true for cameras that must always use the sub-stream (confirmed H.265 main
    /// that iOS AVPlayer can't decode). Currently none — all cameras start on main and fall
    /// back to sub after 3 consecutive failures.
    static func forcesSubStream(_ camera: String) -> Bool { false }
}

// MARK: - Live HLS model

/// Owns one tuned-for-live `AVPlayer`, watches for stalls/failures, and rebuilds with
/// exponential-backoff reconnect. On the first failure it tries a silent token refresh
/// before backoff. After 3 main-stream failures it downgrades to the sub-stream.
@MainActor
final class HLSLiveModel: ObservableObject {
    enum State: Equatable {
        case connecting
        case playing
        case failed(String)
    }

    @Published private(set) var state: State = .connecting
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isMuted = true
    @Published private(set) var usingFallback = false

    private var makeURL: (() -> URL?)?
    private var makeSubURL: (() -> URL?)?
    private var makeItem: ((URL) -> AVPlayerItem?)?
    private var reauth: (() async -> Bool)?
    /// Start on the lighter `_sub` stream (camera wall / grid — keeps many simultaneous
    /// feeds smooth on real hardware), falling back to main if sub is unavailable. The
    /// full-screen viewer leaves this false so a single focused camera plays full quality.
    private var preferSub = false
    /// Whether to auto-pause when the app backgrounds. Wall tiles pause (save battery/data); the
    /// full-screen viewer leaves the player running so auto-Picture-in-Picture can take over on
    /// background instead of being frozen by an eager pause.
    var pausesOnBackground = true

    // These observer tokens are mutated only on the main actor, but `deinit` (which is
    // nonisolated) must remove them — and their teardown APIs (KVO invalidate,
    // removeTimeObserver, NotificationCenter.removeObserver, Task.cancel) are all
    // thread-safe — so they're `nonisolated(unsafe)`. `timeObserverPlayer` mirrors the player
    // the periodic observer was added to, so deinit can balance removeTimeObserver without
    // touching the MainActor-isolated `@Published player`.
    private nonisolated(unsafe) var statusObs: NSKeyValueObservation?
    private nonisolated(unsafe) var timeControlObs: NSKeyValueObservation?
    private nonisolated(unsafe) var sizeObs: NSKeyValueObservation?
    private nonisolated(unsafe) var timeObserver: Any?
    private nonisolated(unsafe) var timeObserverPlayer: AVPlayer?
    private nonisolated(unsafe) var stallObs: NSObjectProtocol?
    private nonisolated(unsafe) var failObs: NSObjectProtocol?
    private nonisolated(unsafe) var reconnectTask: Task<Void, Never>?
    /// True once we took the shared audio session for unmuted playback, so we deactivate it
    /// again on re-mute / stop / dealloc — otherwise one unmute would duck the user's music
    /// for the rest of the app session.
    private nonisolated(unsafe) var didActivateAudio = false
    /// Playback-progress watchdog: a stream only counts as live once its time actually
    /// advances (real frames presented). A frozen/black "playing" stream never does.
    private var lastProgressTime: Double?
    private var advancingConfirmed = false
    private var retryCount = 0
    /// Attempts across BOTH streams since the last successful play. Drives the eventual
    /// give-up, and (once > 0) switches the player into patient buffering.
    private var totalAttempts = 0
    private var didTryReauth = false
    private var isStopped = false
    /// Whether the current connect used patient buffering — recorded so that a camera
    /// which only started once we were patient is remembered as slow-starting.
    private var connectedPatient = false
    /// Identifies the camera for the slow-start memory below.
    private var cameraName = ""
    private nonisolated(unsafe) var lifecycleObservers: [NSObjectProtocol] = []

    /// Cameras observed this session to need patient buffering (e.g. a doorbell with a
    /// long ~4s keyframe interval). Lets a reopen start patient instead of stalling once.
    @MainActor private static var slowStartCameras: Set<String> = []


    func configure(
        cameraName: String = "",
        preferSub: Bool = false,
        makeURL: @escaping () -> URL?,
        makeSubURL: (() -> URL?)? = nil,
        makeItem: @escaping (URL) -> AVPlayerItem?,
        reauth: @escaping () async -> Bool
    ) {
        self.cameraName = cameraName
        self.preferSub = preferSub
        self.makeURL = makeURL
        self.makeSubURL = makeSubURL
        self.makeItem = makeItem
        self.reauth = reauth
    }

    func start() {
        isStopped = false
        retryCount = 0
        totalAttempts = 0
        didTryReauth = false
        usingFallback = false
        observeLifecycle()
        connect()
    }

    /// Pause decoding when the app backgrounds (SwiftUI `onDisappear` does NOT fire on
    /// backgrounding, so without this the AVPlayer keeps pulling + decoding HLS — wasted
    /// battery/data, and a stale frame on return). Rebuild a fresh stream on foreground.
    private func observeLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                // Leave the full-screen player running so auto-PiP can take over; only the wall
                // tiles pause to save battery/data.
                guard self.pausesOnBackground else { return }
                self.reconnectTask?.cancel(); self.reconnectTask = nil
                self.player?.pause()
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                // The live edge moved on while suspended — reconnect fresh rather than
                // resuming a stale buffer.
                self.retryCount = 0
                self.totalAttempts = 0
                self.didTryReauth = false
                self.connect()
            }
        })
    }

    private func teardownLifecycle() {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers.removeAll()
    }

    func stop() {
        isStopped = true
        teardownLifecycle()
        reconnectTask?.cancel()
        reconnectTask = nil
        releaseAudioSession()
        // Capture player before nilling so teardownObservers can remove the time observer.
        let p = player
        player = nil
        teardownObservers(player: p)
        p?.pause()
    }

    func toggleMute() {
        isMuted.toggle()
        if !isMuted {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try? AVAudioSession.sharedInstance().setActive(true)
            didActivateAudio = true
        } else {
            // Hand the session back so the user's music/podcast resumes instead of staying ducked.
            releaseAudioSession()
        }
        player?.isMuted = isMuted
    }

    /// Deactivate the shared audio session if we took it, letting other apps' audio resume.
    private func releaseAudioSession() {
        guard didActivateAudio else { return }
        didActivateAudio = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func reload() {
        // Cancel any pending reconnect so a tapped Retry can't spawn a competing connect.
        reconnectTask?.cancel(); reconnectTask = nil
        retryCount = 0
        totalAttempts = 0
        didTryReauth = false
        usingFallback = false
        connect()
    }

    private func connect() {
        // Wall/grid start on sub and fall back to main; the full-screen viewer starts on
        // main (full quality) and falls back to sub. So the fallback is always "the other".
        let primary = preferSub ? makeSubURL : makeURL
        let fallback = preferSub ? makeURL : makeSubURL
        let urlSource = (usingFallback ? fallback : primary) ?? makeURL
        guard !isStopped, let makeItem, let url = urlSource?(), let item = makeItem(url) else { return }
        teardownObservers(player: player)
        player?.pause()
        lastProgressTime = nil
        advancingConfirmed = false

        // Patient buffering for cameras with a long keyframe interval (e.g. a doorbell
        // with a ~4s GOP). A fresh, never-stalled short-GOP stream stays low-latency;
        // once anything has stalled this session — or this camera is already known to be
        // slow — we let AVPlayer wait for a decodable keyframe instead of failing fast
        // into a reconnect (which is what was turning the doorbell black).
        let patient = totalAttempts > 0 || Self.slowStartCameras.contains(cameraName)
        connectedPatient = patient
        item.preferredForwardBufferDuration = patient ? 6 : 2

        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.automaticallyWaitsToMinimizeStalling = patient
        newPlayer.actionAtItemEnd = .none
        newPlayer.isMuted = isMuted
        player = newPlayer
        state = .connecting

        statusObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                self.handleStatus(item)
            }
        }
        timeControlObs = newPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                self.evaluatePlaying()
            }
        }
        // Treat the stream as "playing" only once it actually has video. Some broken
        // sources (e.g. a doorbell whose go2rtc HLS yields no decodable video) report
        // timeControlStatus == .playing while rendering black; gating on a non-zero
        // presentationSize means those never count as playing, so the fallback timer
        // fires and we switch to MJPEG instead of sitting on a black frame.
        sizeObs = item.observe(\.presentationSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                self.evaluatePlaying()
            }
        }
        // Watchdog: confirm playback time is actually advancing (frames presented). A
        // stream that reports "playing" but is frozen/black never advances, so it never
        // counts as live and the fallback to MJPEG fires.
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverPlayer = newPlayer
        timeObserver = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                let secs = time.seconds
                if let last = self.lastProgressTime, secs > last + 0.05 { self.advancingConfirmed = true }
                self.lastProgressTime = secs
                self.evaluatePlaying()
            }
        }
        stallObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleReconnect(reason: "Reconnecting…") }
        }
        failObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let msg = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "Playback failed"
            Task { @MainActor in self?.handleFailure(msg) }
        }

        newPlayer.play()
    }

    /// Mark the stream live the moment it's playing AND has real video frames
    /// (non-zero presentation size). We intentionally do NOT wait for the
    /// advancing-time watchdog here — that only delays showing the live picture; a
    /// genuinely stuck/black stream is still caught by the MJPEG fallback timer.
    private func evaluatePlaying() {
        guard let player, player.timeControlStatus == .playing,
              let item = player.currentItem, item.presentationSize != .zero else { return }
        state = .playing
        retryCount = 0
        totalAttempts = 0
        didTryReauth = false
        // It only started once we were patient → remember it as slow-starting
        // so the next open begins patient instead of stalling first.
        if connectedPatient, !cameraName.isEmpty {
            Self.slowStartCameras.insert(cameraName)
        }
    }

    private func handleStatus(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            player?.play()
        case .failed:
            handleFailure(item.error?.localizedDescription ?? "Stream error")
        default:
            break
        }
    }

    private func handleFailure(_ message: String) {
        guard !isStopped else { return }
        if !didTryReauth, let reauth {
            didTryReauth = true
            Task { @MainActor in
                if await reauth() { connect() } else { scheduleReconnect(reason: message) }
            }
        } else {
            scheduleReconnect(reason: message)
        }
    }

    private func scheduleReconnect(reason: String) {
        guard !isStopped, reconnectTask == nil else { return }
        retryCount += 1
        totalAttempts += 1

        // Give up only after sustained failure across BOTH streams, not after a single
        // stream stalls — so a camera that can recover keeps trying.
        guard totalAttempts <= 8 else { state = .failed(reason); return }

        // After 3 failures on the current stream, switch main <-> sub. This is a TOGGLE,
        // not a one-way downgrade: a Main-only camera whose `<camera>_sub` 404s flips
        // back to main and recovers, instead of dead-ending on a stream that can't exist
        // (the bug that left the doorbell permanently black).
        if retryCount >= 3, makeSubURL != nil {
            usingFallback.toggle()
            retryCount = 0
            didTryReauth = false
            state = .connecting
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run { self?.reconnectTask = nil; self?.connect() }
            }
            return
        }

        state = .connecting
        let delay = min(pow(2.0, Double(retryCount - 1)), 16)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run { self?.reconnectTask = nil; self?.connect() }
        }
    }

    private func teardownObservers(player explicitPlayer: AVPlayer? = nil) {
        statusObs?.invalidate(); statusObs = nil
        timeControlObs?.invalidate(); timeControlObs = nil
        sizeObs?.invalidate(); sizeObs = nil
        let p = explicitPlayer ?? player
        if let timeObserver { p?.removeTimeObserver(timeObserver) }; timeObserver = nil
        timeObserverPlayer = nil
        if let stallObs { NotificationCenter.default.removeObserver(stallObs) }; stallObs = nil
        if let failObs { NotificationCenter.default.removeObserver(failObs) }; failObs = nil
    }

    /// Persistent tiles (the Cameras wall) only `pause()` on disappear, never `stop()`, so
    /// when their `@StateObject` deallocates on sign-out / server-switch (cameras = []),
    /// `stop()` may never have run. Mirror its teardown here so we never leave a periodic
    /// time observer registered on a deallocating AVPlayer (an AVFoundation crash) or leak
    /// the KVO / NotificationCenter observers. All these APIs are thread-safe, so a
    /// nonisolated deinit is fine. Idempotent with `stop()` (everything is already nil then).
    deinit {
        statusObs?.invalidate()
        timeControlObs?.invalidate()
        sizeObs?.invalidate()
        if let timeObserver, let timeObserverPlayer { timeObserverPlayer.removeTimeObserver(timeObserver) }
        if let stallObs { NotificationCenter.default.removeObserver(stallObs) }
        if let failObs { NotificationCenter.default.removeObserver(failObs) }
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        reconnectTask?.cancel()
        if didActivateAudio {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

// MARK: - Live HLS view

struct HLSLivePlayerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let camera: FrigateCamera
    var showControls: Bool = false
    /// Fades the on-video overlay controls (fill / PiP / mute) in and out with the host's
    /// chrome, so they auto-hide together for a fully immersive full-screen view. Structural
    /// `showControls` (zoom wrapping) stays put so zoom state survives the chrome toggle.
    var overlayControlsVisible: Bool = true
    /// Start on the lighter `_sub` stream — set for the multi-camera wall/grid so many
    /// feeds stay smooth on real hardware. The full-screen viewer leaves this false for
    /// full-quality main-stream playback.
    var preferSub: Bool = false
    /// Keep the stream alive when the view disappears (e.g. switching tabs) instead of
    /// tearing it down — so returning to it is instant and never reloads from black.
    /// Used by the always-on Cameras tab; transient surfaces (wall, full-screen) leave it false.
    var persistent: Bool = false
    /// Pass a controller to enable PiP for this player from outside (e.g. a camera-wall
    /// cell's long-press menu). When nil, the single-camera view uses its own.
    var pipController: LivePiPController? = nil
    /// Single tap on the video (full-screen view) — used to toggle immersive chrome.
    var onSingleTap: (() -> Void)? = nil
    var onPlaying: ((Bool) -> Void)? = nil

    @StateObject private var model = HLSLiveModel()
    @StateObject private var ownPiP = LivePiPController()
    private var pip: LivePiPController { pipController ?? ownPiP }
    @State private var fillMode = false
    /// Tracks whether we've already configured + started this view's player, so a
    /// reappear (tab switch back) resumes instead of restarting from scratch.
    @State private var started = false
    /// When HLS can't establish for this camera (e.g. a doorbell whose go2rtc HLS path is
    /// broken even though the camera is healthy), fall back to Frigate's MJPEG stream —
    /// which Frigate serves itself, not go2rtc — so the view is never stuck on black.
    @State private var mjpegFallback = false
    @State private var fallbackTask: Task<Void, Never>?
    /// Drives the staggered startup through StreamGate so a wall of cameras doesn't all begin
    /// negotiating + decoding at once on launch.
    @State private var startTask: Task<Void, Never>?
    @State private var gateHeld = false

    /// Cameras whose HLS proved unavailable this session — reopened straight on MJPEG so
    /// they don't sit black waiting for HLS to fail every single time.
    @MainActor private static var hlsUnavailable: Set<String> = []

    private var isPlaying: Bool { model.state == .playing }

    /// Whether we already have a cached frame to show. When we do, we connect live
    /// SILENTLY behind it — no "Connecting…" pill — so the camera feels instant
    /// instead of looking like it's loading over an image that's right there.
    /// Birdseye has no latest.jpg, so it never has a cached snapshot.
    private var hasSnapshot: Bool {
        guard camera.name != "birdseye",
              let url = appState.client?.latestFrameURL(camera: camera.name) else { return false }
        return ImageCache.shared.image(for: url) != nil
    }

    /// The AVPlayer layer. In the fullscreen player (`showControls`) it's wrapped in a
    /// `ZoomableScrollView` for smooth native pinch / double-tap / pan zoom (the same engine
    /// the snapshots and clips use). In grid/card cells it's a plain, non-interactive layer.
    @ViewBuilder
    private func playerLayer(_ player: AVPlayer) -> some View {
        if showControls {
            ZoomableScrollView(onSingleTap: onSingleTap) {
                ZoomablePlayerView(
                    player: player,
                    videoGravity: fillMode ? .resizeAspectFill : .resizeAspect,
                    pip: pip,
                    autoPiP: true
                )
            }
            .opacity(isPlaying ? 1 : 0)
            .animation(.easeIn(duration: 0.3), value: isPlaying)
            .allowsHitTesting(true)
        } else {
            // Wall cells: wire PiP only when a controller was provided (long-press menu).
            ZoomablePlayerView(player: player, pip: pipController, autoPiP: false)
                .opacity(isPlaying ? 1 : 0)
                .animation(.easeIn(duration: 0.3), value: isPlaying)
                .allowsHitTesting(false)
        }
    }

    /// MJPEG fallback view — shown when HLS is unavailable for this camera.
    @ViewBuilder
    private func mjpegPlayer(_ client: FrigateClient) -> some View {
        let stream = MJPEGStreamView(
            url: client.mjpegURL(camera: camera.name),
            client: client,
            contentMode: fillMode ? .scaleAspectFill : .scaleAspectFit,
            onFirstFrame: { onPlaying?(true) }
        )
        if showControls {
            ZoomableScrollView(onSingleTap: onSingleTap) { stream }
        } else {
            stream
        }
    }

    /// Give HLS a short window to start; if it never does (or it gives up), switch to MJPEG.
    /// Release this view's startup slot back to the gate exactly once (idempotent).
    private func releaseGate() {
        guard gateHeld else { return }
        gateHeld = false
        Task { await StreamGate.shared.release() }
    }

    private func startFallbackTimer() {
        fallbackTask?.cancel()
        fallbackTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, !isPlaying else { return }
            fallToMJPEG()
        }
    }

    private func fallToMJPEG() {
        guard !mjpegFallback else { return }
        fallbackTask?.cancel(); fallbackTask = nil
        // Free the startup slot now — model.stop() doesn't change model.state, so the
        // onChange(.playing/.failed) release won't fire for the timer-driven fallback path.
        releaseGate()
        Self.hlsUnavailable.insert(camera.name)
        model.stop()
        withAnimation(reduceMotion ? nil : .easeIn(duration: 0.25)) { mjpegFallback = true }
    }

    var body: some View {
        ZStack {
            Color.black

            // Snapshot placeholder — shows instantly so there's never a black gap.
            // Sits behind the video layer and fades out the moment the stream is live.
            // Birdseye has no latest.jpg, so skip the attempt to avoid a guaranteed 404.
            if camera.name != "birdseye",
               let url = appState.client?.latestFrameURL(camera: camera.name) {
                RemoteImage(url: url, contentMode: .fit)
                    .opacity(isPlaying ? 0 : 1)
                    .animation(.easeOut(duration: 0.3), value: isPlaying)
                    .allowsHitTesting(false)
            }

            // AVPlayer layer — invisible until actually playing, then fades in cleanly.
            // Pinch / pan / double-tap zoom handled via SwiftUI gestures when showControls.
            // Once HLS is deemed unavailable, the MJPEG fallback takes over instead.
            if mjpegFallback, let client = appState.client {
                mjpegPlayer(client)
            } else if let player = model.player {
                playerLayer(player)
            }

            // Subtle connecting pill — only when there's no frame to show yet. If a
            // snapshot is already on screen, we connect silently for an instant feel.
            if model.state == .connecting, !mjpegFallback, !hasSnapshot {
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        ProgressView().tint(.white).scaleEffect(0.65)
                        Text(model.usingFallback ? "Reconnecting…" : "Connecting…")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.bottom, 14)
                }
                .allowsHitTesting(false)
            }

            if case .failed(let message) = model.state, !mjpegFallback {
                failureOverlay(message)
            }

            if showControls {
                liveControls
                    .opacity(overlayControlsVisible ? 1 : 0)
                    .allowsHitTesting(overlayControlsVisible)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: overlayControlsVisible)
            }
        }
        .onAppear {
            // Returning to a kept-alive player (tab switch back) — just resume, instantly.
            if started {
                if mjpegFallback == false { model.player?.play() }
                return
            }
            started = true
            // Skip the HLS wait for cameras already known to need MJPEG this session.
            if Self.hlsUnavailable.contains(camera.name) {
                mjpegFallback = true
                return
            }
            model.configure(
                cameraName: camera.name,
                preferSub: preferSub,
                makeURL: { appState.client?.liveHLSURL(camera: camera.name, sub: false) },
                makeSubURL: { appState.client?.liveHLSURL(camera: camera.name, sub: true) },
                makeItem: { url in appState.client?.playerItem(for: url) },
                reauth: { await appState.reauthenticate() }
            )
            // Full-screen viewer (showControls + autoPiP) keeps playing on background so PiP can
            // start; wall/grid tiles pause to save power.
            model.pausesOnBackground = !showControls
            // Stagger startup behind the shared gate so a full wall doesn't stampede at once.
            startTask = Task { @MainActor in
                await StreamGate.shared.acquire()
                gateHeld = true
                guard !Task.isCancelled, started else { releaseGate(); return }
                model.start()
                startFallbackTimer()
                // Safety release if the stream never reports playing/failed (don't wedge the gate).
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                releaseGate()
            }
        }
        .onDisappear {
            startTask?.cancel(); startTask = nil
            releaseGate()
            // Stop publishing to the system playback UI when the full-screen viewer closes.
            if showControls { NowPlayingController.shared.detach(player: model.player) }
            if persistent {
                if model.player == nil {
                    // Disappeared before the gate handed us a slot (player never built), so
                    // there's nothing to keep alive — reset so reappear re-runs the full
                    // setup instead of short-circuiting on `started` and stranding the tile
                    // on its snapshot forever.
                    started = false
                    fallbackTask?.cancel(); fallbackTask = nil
                } else {
                    // Keep it loaded across tab switches — just pause decoding. The last
                    // frame stays on screen, so returning is instant with no black flash.
                    model.player?.pause()
                }
            } else {
                model.stop()
                fallbackTask?.cancel(); fallbackTask = nil
                started = false
            }
        }
        .onChange(of: model.state) { _, newState in
            onPlaying?(newState == .playing)
            switch newState {
            case .playing:
                fallbackTask?.cancel(); fallbackTask = nil; releaseGate()  // up — free the slot
                // Full-screen viewer publishes this camera to the system playback UI
                // (Lock Screen / Control Center / Dynamic Island / CarPlay). Wall tiles don't.
                if showControls, let player = model.player {
                    NowPlayingController.shared.attach(
                        player: player, title: titleize(camera.name), subtitle: "Live", isLive: true
                    )
                }
            case .failed: releaseGate(); fallToMJPEG()                                 // gave up — free + MJPEG
            default: break
            }
        }
    }

    private var liveControls: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Spacer()
                Button {
                    Haptics.tap()
                    fillMode.toggle()
                } label: {
                    Image(systemName: fillMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .black))
                        .frame(width: 40, height: 40)
                        .liquidGlass(in: Circle(), interactive: true, fallbackMaterial: .ultraThinMaterial)
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(fillMode ? "Fit to screen" : "Fill screen")
                if pip.isSupported {
                    Button {
                        Haptics.tap()
                        pip.toggle()
                    } label: {
                        Image(systemName: pip.isActive ? "pip.exit" : "pip.enter")
                            .font(.system(size: 14, weight: .black))
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel(pip.isActive ? "Exit Picture in Picture" : "Picture in Picture")
                }
                Button {
                    Haptics.tap()
                    model.toggleMute()
                } label: {
                    Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 14, weight: .black))
                        .frame(width: 40, height: 40)
                        .liquidGlass(in: Circle(), interactive: true, fallbackMaterial: .ultraThinMaterial)
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(model.isMuted ? "Unmute" : "Mute")
            }
            .glassGroup(spacing: 10)
            .padding(.trailing, 14)
            .padding(.bottom, 8)
        }
        // Only the buttons are tappable — the rest passes zoom gestures through.
        .allowsHitTesting(true)
    }

    private func failureOverlay(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, options: reduceMotion ? .nonRepeating : .repeating)
            Text(message)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Button { model.reload() } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.white, in: Capsule())
            }
        }
    }
}

// MARK: - Picture in Picture

/// Drives Picture in Picture for a live `AVPlayerLayer`. SwiftUI holds one of these,
/// passes it to `ZoomablePlayerView`, and toggles PiP from a button.
@MainActor
final class LivePiPController: ObservableObject {
    @Published var isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    @Published var isPossible = false
    @Published var isActive = false
    fileprivate weak var controller: AVPictureInPictureController?

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        }
    }
}

// MARK: - AVPlayerLayer view with pinch / pan / double-tap zoom (+ optional PiP)

struct ZoomablePlayerView: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    /// When set, Picture in Picture is wired to this layer and surfaced through the controller.
    var pip: LivePiPController? = nil
    /// Float into PiP automatically when the app backgrounds while this is playing inline.
    var autoPiP: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(pip: pip, autoPiP: autoPiP) }

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        context.coordinator.attach(to: view.playerLayer)
        return view
    }

    func updateUIView(_ view: PlayerLayerUIView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        view.playerLayer.videoGravity = videoGravity
    }

    final class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
        private let pip: LivePiPController?
        private let autoPiP: Bool
        private var controller: AVPictureInPictureController?
        private var possibleObs: NSKeyValueObservation?

        init(pip: LivePiPController?, autoPiP: Bool) {
            self.pip = pip
            self.autoPiP = autoPiP
        }

        // Called from makeUIView (main thread). State is pushed to the @MainActor
        // controller via Task to keep concurrency clean across Swift versions.
        func attach(to layer: AVPlayerLayer) {
            // AVPictureInPictureController(playerLayer:) is failable on some SDKs.
            guard pip != nil, controller == nil,
                  AVPictureInPictureController.isPictureInPictureSupported(),
                  let controller = AVPictureInPictureController(playerLayer: layer) else { return }
            controller.canStartPictureInPictureAutomaticallyFromInline = autoPiP
            controller.delegate = self
            self.controller = controller
            let pip = self.pip
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor in
                pip?.controller = controller
                pip?.isPossible = possible
            }
            possibleObs = controller.observe(\.isPictureInPicturePossible, options: [.new]) { c, _ in
                let value = c.isPictureInPicturePossible
                Task { @MainActor in pip?.isPossible = value }
            }
        }

        func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
            let pip = self.pip
            Task { @MainActor in pip?.isActive = true }
        }

        func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
            let pip = self.pip
            Task { @MainActor in pip?.isActive = false }
        }
    }
}

final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }
}
