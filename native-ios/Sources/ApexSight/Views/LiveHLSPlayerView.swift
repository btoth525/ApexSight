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
    /// True while this player's view is OFF-SCREEN (persistent wall tile on a hidden tab).
    /// Foregrounding the app must NOT rebuild streams for invisible tiles — that was spinning up
    /// all 8 wall decoders behind the Settings tab on every foreground. The tile reconnects
    /// itself in onAppear when it actually comes back.
    var isOffscreen = false

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
    /// Grace timer that lets a transient stall (motion bitrate spike) rebuffer in place before we
    /// escalate to a reconnect — so smooth playback isn't interrupted by a needless rebuild.
    private nonisolated(unsafe) var stallGraceTask: Task<Void, Never>?
    /// True for the focused full-screen viewer — enables the rebuffer-in-place grace instead of
    /// reconnect-on-stall.
    private var focusedSmooth = false
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
                guard let self, !self.isStopped, !self.isOffscreen else { return }
                // The live edge moved on while suspended — reconnect fresh rather than
                // resuming a stale buffer. (Off-screen persistent tiles skip this and
                // reconnect in onAppear instead.)
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
        stallGraceTask?.cancel()
        stallGraceTask = nil
        releaseAudioSession()
        // Capture player before nilling so teardownObservers can remove the time observer.
        let p = player
        player = nil
        teardownObservers(player: p)
        if let p, !focusedSmooth { WallPlayerRegistry.shared.unregister(p, for: cameraName) }
        p?.pause()
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    /// Host-driven mute state (the viewer's uniform Audio button routes here).
    func setMuted(_ muted: Bool) {
        guard muted != isMuted || player?.isMuted != muted else { return }
        isMuted = muted
        if !muted {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try? AVAudioSession.sharedInstance().setActive(true)
            didActivateAudio = true
        } else {
            // Hand the session back so the user's music/podcast resumes instead of staying ducked.
            releaseAudioSession()
        }
        player?.isMuted = muted
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
        stallGraceTask?.cancel(); stallGraceTask = nil
        player?.pause()
        lastProgressTime = nil
        advancingConfirmed = false

        // The focused full-screen viewer (single main-stream camera) biases for SMOOTH playback:
        // a moderate forward buffer + letting AVPlayer rebuffer gracefully, so a motion bitrate
        // spike freezes on the last frame for a beat and resumes — instead of the old behavior
        // where any stall tore the stream down and jumped to the live edge (the visible skip).
        // The multi-camera wall stays lean/low-latency so many feeds don't stampede memory.
        let focused = !preferSub
        focusedSmooth = focused
        // Patient buffering for cameras with a long keyframe interval (e.g. a doorbell
        // with a ~4s GOP). A fresh, never-stalled short-GOP stream stays low-latency;
        // once anything has stalled this session — or this camera is already known to be
        // slow — we let AVPlayer wait for a decodable keyframe instead of failing fast.
        let patient = totalAttempts > 0 || Self.slowStartCameras.contains(cameraName)
        connectedPatient = patient
        item.preferredForwardBufferDuration = focused ? 5 : (patient ? 6 : 2)

        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.automaticallyWaitsToMinimizeStalling = focused ? true : patient
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
            Task { @MainActor in self?.handleStall() }
        }
        failObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let msg = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "Playback failed"
            Task { @MainActor in self?.handleFailure(msg) }
        }

        // Fast start + smooth playback: `playImmediately` begins the moment the first frames
        // are decodable instead of waiting for the full forward buffer (the focused viewer's
        // `automaticallyWaitsToMinimizeStalling = true` would otherwise delay first frame by
        // seconds). If it outruns the buffer, the stall-grace path rebuffers in place — no
        // teardown, no skip. Wall tiles keep plain play() (their lean config already starts fast).
        if focused { newPlayer.playImmediately(atRate: 1.0) } else { newPlayer.play() }
    }

    /// Mark the stream live the moment it's playing AND has real video frames
    /// (non-zero presentation size). We intentionally do NOT wait for the
    /// advancing-time watchdog here — that only delays showing the live picture; a
    /// genuinely stuck/black stream is still caught by the MJPEG fallback timer.
    private func evaluatePlaying() {
        guard let player, player.timeControlStatus == .playing,
              let item = player.currentItem, item.presentationSize != .zero else { return }
        state = .playing
        // A stream that stalled, scheduled a reconnect, then recovered on its own must cancel
        // that pending reconnect — otherwise it fires later and needlessly rebuilds a live,
        // playing stream (a visible black flash).
        reconnectTask?.cancel(); reconnectTask = nil
        stallGraceTask?.cancel(); stallGraceTask = nil
        // Wall tiles publish their warm, already-decoding player so the full-screen viewer
        // can open on it instantly (zero-latency handoff).
        if !focusedSmooth { WallPlayerRegistry.shared.register(player, for: cameraName) }
        retryCount = 0
        totalAttempts = 0
        didTryReauth = false
        // It only started once we were patient → remember it as slow-starting
        // so the next open begins patient instead of stalling first.
        if connectedPatient, !cameraName.isEmpty {
            Self.slowStartCameras.insert(cameraName)
        }
    }

    /// A playback stall fired. In the focused viewer we do NOT immediately reconnect (that flips
    /// state to .connecting, fades the video out, and rebuilds to the live edge — the visible
    /// skip). Instead we hold the current frame and give AVPlayer a grace window to rebuffer.
    /// Only if playback still hasn't advanced after the window do we escalate — so a genuinely
    /// dead camera (unplugged) still recovers via the reconnect → MJPEG cascade.
    private func handleStall() {
        guard !isStopped else { return }
        guard focusedSmooth else { scheduleReconnect(reason: "Reconnecting…"); return }
        guard stallGraceTask == nil else { return }
        let stalledAt = lastProgressTime ?? 0
        stallGraceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            await MainActor.run {
                guard let self, !self.isStopped else { return }
                self.stallGraceTask = nil
                // Recovered on its own (time advanced, or it's playing again) → nothing to do.
                if self.player?.timeControlStatus == .playing || (self.lastProgressTime ?? 0) > stalledAt + 0.1 {
                    return
                }
                // Still stuck after grace → treat as a real failure.
                self.scheduleReconnect(reason: "Reconnecting…")
            }
        }
    }

    private func handleStatus(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            // Focused viewer: start on the first decodable frame (see connect()) — the
            // stall-grace covers any rebuffer. Wall tiles: standard start.
            if focusedSmooth { player?.playImmediately(atRate: 1.0) } else { player?.play() }
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
        stallGraceTask?.cancel()
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
    /// Reports fit vs. fill (crop) so a host drawing a detection overlay can map boxes into the
    /// same displayed video rect. Fires on toggle and on appear.
    var onFillModeChange: ((Bool) -> Void)? = nil
    /// Reports when the fisheye dewarp takes over the presentation, so a host can hide
    /// overlays whose coordinates only make sense on the raw frame (detection boxes).
    var onDewarpChange: ((Bool) -> Void)? = nil
    /// External control mode (the full-screen viewer): the HOST renders every control in
    /// its own uniform action grid, so this view shows no floating overlay buttons at all.
    var externalControls: Bool = false
    /// Host-owned mute state (external control mode). nil = self-managed.
    var muted: Bool? = nil
    /// Host-owned fisheye view mode (external control mode). nil = self-managed.
    var dewarpModeOverride: DewarpMode? = nil

    @StateObject private var model = HLSLiveModel()
    /// Sub-second WebRTC live for the focused viewer — overlays the HLS layer when healthy,
    /// costs nothing when it can't connect (HLS keeps running underneath either way).
    @StateObject private var realtime = RealtimeVideoController()
    /// The wall tile's already-decoding player, shown INSTANTLY while this view's own
    /// full-quality stream connects (zero-latency handoff). Cleared once handoff completes.
    @State private var warmPlayer: AVPlayer?
    @ObservedObject private var fisheyeStore = FisheyeStore.shared
    /// Fisheye cameras open straight into virtual PTZ — the raw warped disc is never
    /// what the user wants first. Ignored (and no UI shown) for normal cameras.
    @State private var dewarpMode: DewarpMode = .ptz
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
    /// True once the MJPEG fallback itself fails to connect (a genuinely offline camera) — drives
    /// the retry overlay so the view never sits on "Connecting…" forever. Reset whenever we
    /// (re)enter the MJPEG path or retry.
    @State private var mjpegFailed = false
    @State private var fallbackTask: Task<Void, Never>?
    /// Drives the staggered startup through StreamGate so a wall of cameras doesn't all begin
    /// negotiating + decoding at once on launch.
    @State private var startTask: Task<Void, Never>?
    @State private var gateHeld = false

    /// Cameras whose HLS proved unavailable this session — reopened straight on MJPEG so
    /// they don't sit black waiting for HLS to fail every single time.
    @MainActor private static var hlsUnavailable: Set<String> = []

    private var isPlaying: Bool { model.state == .playing }

    /// Realtime (WebRTC) is attempted only for the focused viewer, on normal cameras, while
    /// muted (unmuting switches to HLS so audio+video stay in sync from one pipeline).
    private var realtimeEligible: Bool {
        showControls && !mjpegFallback && camera.name != "birdseye" && !fisheyeStore.isFisheye(camera.name)
    }

    private var effectiveMuted: Bool { muted ?? model.isMuted }

    /// The fisheye view mode in effect — host-owned when overridden, else internal state.
    private var effectiveDewarpMode: DewarpMode { dewarpModeOverride ?? dewarpMode }

    /// The Metal dewarp presentation is live in the full-screen viewer: a user-marked
    /// fisheye camera in any mode but Raw, or the quad multi-view.
    private var dewarpActive: Bool {
        showControls && fisheyeStore.isFisheye(camera.name)
            && (quadActive || effectiveDewarpMode != .off)
    }

    /// Verkada-style four-pane multi-view, persisted per camera.
    private var quadActive: Bool {
        fisheyeStore.config(for: camera.name).quadEnabled
    }

    private var fisheyeLocked: Bool {
        fisheyeStore.config(for: camera.name).locked
    }

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
                ZStack {
                    ZoomablePlayerView(
                        player: player,
                        videoGravity: fillMode ? .resizeAspectFill : .resizeAspect,
                        pip: pip,
                        autoPiP: true
                    )
                    // Sub-second realtime layer — INSIDE the zoom container so pinch/pan
                    // zoom applies to it too. Fades in only once a real frame rendered.
                    if let track = realtime.videoTrack {
                        RealtimeVideoView(track: track) { realtime.noteFirstFrame() }
                            .opacity(realtime.state == .live ? 1 : 0)
                            .animation(.easeIn(duration: 0.25), value: realtime.state)
                            .allowsHitTesting(false)
                    }
                }
            }
            .opacity(isPlaying || realtime.state == .live ? 1 : 0)
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
            onFirstFrame: {
                mjpegFailed = false
                onPlaying?(true)
            },
            onError: {
                // MJPEG is our last resort; if it can't connect either, the camera is offline.
                // Surface a retry instead of an eternal "Connecting…".
                onPlaying?(false)
                withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) { mjpegFailed = true }
            }
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
        mjpegFailed = false
        withAnimation(reduceMotion ? nil : .easeIn(duration: 0.25)) { mjpegFallback = true }
    }

    /// Point the model at this camera's HLS endpoints. Idempotent — just installs closures —
    /// so it's safe to call from both first appearance and a retry after teardown.
    private func configureModel() {
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
    }

    /// Start/stop the sub-second WebRTC layer to match current conditions: focused viewer,
    /// normal camera, muted. Unmuting stops it — HLS then carries audio+video from ONE
    /// pipeline, so sound is never out of sync with the picture.
    private func syncRealtime() {
        guard realtimeEligible, let client = appState.client else { realtime.stop(); return }
        if effectiveMuted {
            if realtime.state == .idle || realtime.state == .failed {
                // Main first (full quality where it's H264), then the H264 sub-stream so even
                // HEVC-main cameras (Front Driveway) get sub-second live at reduced resolution.
                realtime.start(sources: [camera.name, "\(camera.name)_sub"], client: client)
            }
        } else {
            realtime.stop()
        }
    }

    /// The real stream (HLS or realtime) is on screen — hand the borrowed wall player back.
    private func completeHandoff() {
        guard let warm = warmPlayer else { return }
        warm.pause()
        warmPlayer = nil
    }

    /// Retry an offline camera from scratch: forget the "HLS unavailable" verdict, leave the
    /// MJPEG fallback, and re-run the full HLS → MJPEG cascade so a camera that just came back
    /// online recovers on tap.
    private func retry() {
        mjpegFailed = false
        Self.hlsUnavailable.remove(camera.name)
        withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) { mjpegFallback = false }
        configureModel()
        model.start()
        startFallbackTimer()
    }

    var body: some View {
        ZStack {
            Color.black

            // Snapshot placeholder — shows instantly so there's never a black gap.
            // Sits behind the video layer and fades out the moment the stream is live.
            // Birdseye has no latest.jpg, so skip the attempt to avoid a guaranteed 404.
            if camera.name != "birdseye",
               let url = appState.client?.latestFrameURL(camera: camera.name) {
                // `latest.jpg` changes constantly — stale-while-revalidate so the placeholder
                // behind a connecting/reconnecting stream is the CURRENT frame, not the one
                // cached at app launch (which could be hours old).
                RemoteImage(url: url, contentMode: .fit, revalidate: true)
                    .opacity(isPlaying ? 0 : 1)
                    .animation(.easeOut(duration: 0.3), value: isPlaying)
                    .allowsHitTesting(false)
            }

            // Zero-latency handoff: the wall tile's ALREADY-DECODING player shows moving video
            // the instant the full-screen viewer opens, while the full-quality stream connects
            // behind it. Skipped for fisheye (the tile renders through Metal dewarp, not a raw
            // layer we can borrow). Removed the moment the real stream is up.
            if showControls, !isPlaying, realtime.state != .live, let warm = warmPlayer {
                ZoomablePlayerView(player: warm, videoGravity: .resizeAspect)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            // AVPlayer layer — invisible until actually playing, then fades in cleanly.
            // Pinch / pan / double-tap zoom handled via SwiftUI gestures when showControls.
            // Once HLS is deemed unavailable, the MJPEG fallback takes over instead.
            if mjpegFallback, let client = appState.client {
                mjpegPlayer(client)
            } else if let player = model.player {
                if dewarpActive {
                    // Metal fisheye dewarp replaces the AVPlayerLayer; the player keeps
                    // decoding (the renderer taps its frames via AVPlayerItemVideoOutput)
                    // and all reconnect/fallback logic stays live underneath.
                    Group {
                        if quadActive {
                            FisheyeQuadView(player: player, camera: camera, onSingleTap: onSingleTap)
                        } else {
                            FisheyeDewarpView(
                                player: player,
                                camera: camera,
                                mode: effectiveDewarpMode,
                                onSingleTap: onSingleTap
                            )
                        }
                    }
                    .opacity(isPlaying ? 1 : 0)
                    .animation(.easeIn(duration: 0.3), value: isPlaying)
                } else if !showControls, fisheyeStore.isFisheye(camera.name),
                          let savedMode = DewarpMode(rawValue: fisheyeStore.pose(for: camera.name, pane: nil).mode),
                          savedMode != .off {
                    // Wall tile: show the SAME saved dewarped view the viewer uses —
                    // Verkada-style — instead of the raw warped disc. Gestures off
                    // (the tile's tap/long-press behaviors stay with the cell).
                    FisheyeDewarpView(
                        player: player,
                        camera: camera,
                        mode: savedMode,
                        interactive: false
                    )
                    .opacity(isPlaying ? 1 : 0)
                    .animation(.easeIn(duration: 0.3), value: isPlaying)
                    .allowsHitTesting(false)
                } else {
                    playerLayer(player)
                }
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

            // A hard HLS `.failed` immediately falls through to MJPEG (see onChange below), so the
            // only failure the user actually sees is when MJPEG — the last resort — can't connect
            // either. That means the camera is genuinely offline: show a retry instead of
            // stranding the view on the snapshot with a spinning "Connecting…".
            if mjpegFallback, mjpegFailed {
                failureOverlay("Camera offline")
            }

            if showControls, !externalControls {
                liveControls
                    .opacity(overlayControlsVisible ? 1 : 0)
                    .allowsHitTesting(overlayControlsVisible)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: overlayControlsVisible)
            }

            // Sub-second mode indicator — you're seeing the camera essentially as it happens.
            if showControls, realtime.state == .live {
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.fill").font(.system(size: 9, weight: .black))
                            Text("REALTIME").font(.system(size: 9, weight: .black)).tracking(0.8)
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(GlassTheme.green, in: Capsule())
                        .padding(.trailing, 14).padding(.top, 10)
                    }
                    Spacer()
                }
                .opacity(overlayControlsVisible ? 1 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: overlayControlsVisible)
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            // Zero-latency handoff: borrow the wall tile's warm player immediately.
            if showControls, camera.name != "birdseye", !fisheyeStore.isFisheye(camera.name),
               let warm = WallPlayerRegistry.shared.player(for: camera.name) {
                warmPlayer = warm
                warm.playImmediately(atRate: 1.0)
            }
            syncRealtime()
            // Host-owned mute (external control mode) applies from the first frame.
            if let muted { model.setMuted(muted) }
            // Reopen exactly how the user left this camera — saved mode rides in the pose.
            // (Skipped when the host owns the mode — it restores/persists itself.)
            if dewarpModeOverride == nil, fisheyeStore.isFisheye(camera.name),
               let saved = DewarpMode(rawValue: fisheyeStore.pose(for: camera.name, pane: nil).mode) {
                dewarpMode = saved
            }
            #if DEBUG
            // Sim-driving hook: synthetic taps can't reliably reach the bottom control row
            // (home-indicator gesture band), so tests inject the dewarp mode via the app group.
            if let raw = UserDefaults(suiteName: ApexAppGroup.identifier)?
                .object(forKey: "apex.debug.dewarpMode") as? Int,
               let injected = DewarpMode(rawValue: Int32(raw)) {
                dewarpMode = injected
            }
            #endif
            onDewarpChange?(dewarpActive)
            // Returning to a kept-alive player (tab switch back) — just resume, instantly.
            if started {
                model.isOffscreen = false
                if mjpegFallback == false { model.player?.play() }
                return
            }
            model.isOffscreen = false
            started = true
            // Skip the HLS wait for cameras already known to need MJPEG this session.
            if Self.hlsUnavailable.contains(camera.name) {
                mjpegFallback = true
                return
            }
            configureModel()
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
            realtime.stop()
            // Un-claimed warm player goes back to rest (the tile resumes it in its own onAppear).
            if let warm = warmPlayer { warm.pause(); warmPlayer = nil }
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
                    // Marked off-screen so an app foreground doesn't rebuild this hidden
                    // tile's stream (it reconnects itself in onAppear).
                    model.isOffscreen = true
                    model.player?.pause()
                }
            } else {
                model.stop()
                fallbackTask?.cancel(); fallbackTask = nil
                started = false
            }
        }
        .onChange(of: muted) { _, newValue in
            if let newValue { model.setMuted(newValue) }
            syncRealtime()
        }
        .onChange(of: model.isMuted) { _, _ in
            // Self-managed mute (overlay button) — keep realtime in sync too.
            syncRealtime()
        }
        .onChange(of: realtime.state) { _, newState in
            if newState == .live { completeHandoff() }
        }
        .onChange(of: mjpegFallback) { _, fellBack in
            if fellBack { realtime.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // Realtime stops itself on background; pick it back up when we return.
            syncRealtime()
        }
        .onChange(of: dewarpModeOverride) { _, _ in
            onDewarpChange?(dewarpActive)
        }
        .onChange(of: dewarpMode) { _, newMode in
            // Persist the chosen view mode (including Raw) so the camera reopens —
            // in the viewer AND on the wall tile — exactly how the user left it.
            // (Host-owned mode persists in the host.)
            if dewarpModeOverride == nil, fisheyeStore.isFisheye(camera.name) {
                var pose = fisheyeStore.pose(for: camera.name, pane: nil)
                pose.mode = newMode.rawValue
                fisheyeStore.savePose(camera.name, pane: nil, pose: pose)
            }
            onDewarpChange?(dewarpActive)
        }
        .onChange(of: model.state) { _, newState in
            onPlaying?(newState == .playing)
            switch newState {
            case .playing:
                fallbackTask?.cancel(); fallbackTask = nil; releaseGate()  // up — free the slot
                completeHandoff()   // real stream is up — release the borrowed wall player
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
                if pip.isSupported {
                    Button {
                        Haptics.tap()
                        pip.toggle()
                    } label: {
                        Image(systemName: pip.isActive ? "pip.exit" : "pip.enter")
                            .font(.system(size: 14, weight: .black))
                            .frame(width: 40, height: 40)
                            .liquidGlass(in: Circle(), interactive: true, fallbackMaterial: .ultraThinMaterial)
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
            Button { Haptics.tap(); retry() } label: {
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
            // PiP REQUIRES the app audio session category to be .playback — without it,
            // startPictureInPicture() silently no-ops. The app only set it on UNMUTE, so
            // PiP never worked on a muted stream (the default). Category only — the session
            // is activated by the unmute flow, so this doesn't duck other apps' audio.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
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
