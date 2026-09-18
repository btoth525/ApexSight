import SwiftUI
import UIKit
import VLCKitSPM

/// Native RTSP live player — the way the Reolink app plays the 16 MP Driveway: MobileVLCKit pulls
/// go2rtc's RTSP directly and hardware-decodes H.265/H.264 through VideoToolbox. iPhone WebRTC and
/// AVPlayer can't carry the camera's 16 MP HEVC main; this can.
///
/// It is a ROUTER, not a rewrite. On the home network (`onLocalNetwork`) it plays RTSP with a
/// sub-first → main-swap instant open (like Reolink). Off the LAN — or if VLC fails to render — it
/// falls straight through to the existing `HLSLivePlayerView` cascade (WebRTC / HLS / MJPEG),
/// which is unchanged. So the app behaves exactly as before everywhere VLC isn't the right tool,
/// and reverting is just swapping the type name back at the four call sites. The init surface
/// mirrors `HLSLivePlayerView` 1:1 so those call sites change by name only.
///
/// - Wall/grid tiles pass `preferSub: true` → **sub stream ONLY**, never main. This is structural
///   (the main player is never created in that mode), so a wall of nine tiles can't stampede the
///   phone with 16 MP decodes.
/// - The full-screen viewer leaves `preferSub` false → opens the light `_sub` for an instant frame,
///   then swaps to the full-res main once the main actually renders, releasing the sub player.
struct VLCLivePlayerView: View {
    let camera: FrigateCamera
    var showControls: Bool = false
    var overlayControlsVisible: Bool = true
    var preferSub: Bool = false
    var persistent: Bool = false
    var pipController: LivePiPController? = nil
    var onSingleTap: (() -> Void)? = nil
    var onPlaying: ((Bool) -> Void)? = nil
    var onRealtimeChange: ((Bool) -> Void)? = nil
    var onFillModeChange: ((Bool) -> Void)? = nil
    var externalControls: Bool = false
    var muted: Bool? = nil
    var allowMJPEGFallback: Bool = true
    var realtimeAudio: Bool = false

    // Observe the narrow ImageSession (client + onLocalNetwork + sub-stream facts), NOT AppState —
    // same discipline as the rest of the wall, so a tile doesn't re-render on live-detection churn.
    @ObservedObject private var session = ImageSession.shared
    @StateObject private var controller = VLCLiveController()
    /// One-way latch: once VLC gives up for this view instance, fall through to the HLS cascade and
    /// stay there (a reopened view gets a fresh instance and another VLC attempt).
    @State private var vlcFailed = false
    @Environment(\.scenePhase) private var scenePhase

    /// Wall/grid tiles are sub-only. `preferSub` is exactly the "this is a dense tile, use the light
    /// stream" signal in this codebase; keying off it makes sub-only structural, not a convention.
    private var subOnly: Bool { preferSub }
    private var effectiveMuted: Bool { muted ?? true }

    /// A real `<camera>_sub` go2rtc stream exists. Until the stream list is known, assume one may
    /// (matches the HLS path), so first-launch tiles still start light.
    private var hasSub: Bool {
        !session.subStreamsKnown || session.subStreamCameras.contains(camera.name)
    }

    /// go2rtc source name for the full-res main. The Driveway's plain `Front_Driveway` go2rtc stream
    /// is Scrypted's H.264 rebroadcast; `Front_Driveway_raw` is the camera's real 16 MP HEVC main
    /// (what recording copies). Native RTSP + VideoToolbox is the only phone path that plays it.
    private var mainStreamName: String {
        camera.name == "Front_Driveway" ? "Front_Driveway_raw" : camera.name
    }
    private var subStreamName: String { "\(camera.name)_sub" }

    /// Use native RTSP only where it's the right tool and can work: on the LAN, for a real camera
    /// (birdseye is a go2rtc composite — leave it to HLS), with a derivable RTSP host, and — on the
    /// wall — only when a sub stream actually exists (else the HLS path handles the sub-less camera).
    private var useVLC: Bool {
        session.onLocalNetwork
            && camera.name != "birdseye"
            && !vlcFailed
            && (ImageSession.shared.client?.rtspURL(streamName: camera.name) != nil)
            && (!subOnly || hasSub)
    }

    var body: some View {
        Group {
            if useVLC {
                vlcSurface
            } else {
                // Exact existing behavior — remote, birdseye, sub-less wall tiles, and the VLC
                // fallback all land here. Every parameter is forwarded so nothing changes off-LAN.
                HLSLivePlayerView(
                    camera: camera,
                    showControls: showControls,
                    overlayControlsVisible: overlayControlsVisible,
                    preferSub: preferSub,
                    persistent: persistent,
                    pipController: pipController,
                    onSingleTap: onSingleTap,
                    onPlaying: onPlaying,
                    onRealtimeChange: onRealtimeChange,
                    onFillModeChange: onFillModeChange,
                    externalControls: externalControls,
                    muted: muted,
                    allowMJPEGFallback: allowMJPEGFallback,
                    realtimeAudio: realtimeAudio
                )
            }
        }
    }

    @ViewBuilder
    private var vlcSurface: some View {
        let video = VLCVideoContainerRepresentable(controller: controller)
        Group {
            if showControls {
                // Match HLSLivePlayerView's full-screen surface: pinch-to-zoom + single-tap chrome.
                ZoomableScrollView(onSingleTap: onSingleTap) { video }
            } else {
                video
            }
        }
        .onAppear { startVLC() }
        .onDisappear { controller.stop() }
        // Stop decoding only when the app truly BACKGROUNDS (VLC has no PiP path, so there's nothing
        // to keep alive), and reconnect on return. NOT on `.inactive` — that fires transiently for
        // notification banners, Control Center, the app switcher, and every sheet this viewer opens
        // (quick controls, responses, deterrent, share); tearing down there would reconnect on each.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { startVLC() } else if phase == .background { controller.stop() }
        }
        .onChange(of: effectiveMuted) { _, m in controller.setMuted(m) }
        // Retrigger when the network confirms local (the probe flips `onLocalNetwork` async, after
        // this view may already be mounted) and stop when it drops. `start()` is idempotent, so an
        // extra call alongside `.onAppear` is a no-op.
        .onChange(of: session.onLocalNetwork) { _, local in
            if local { startVLC() } else { controller.stop() }
        }
        // The client can arrive / swap its base URL (local↔remote) after mount; its `identity`
        // changes exactly then. Retry so a tile that mounted before the client was ready still opens.
        .onChange(of: session.client?.identity) { _, _ in startVLC() }
    }

    private func startVLC() {
        guard useVLC, let client = ImageSession.shared.client else { return }
        let subURL = hasSub ? client.rtspURL(streamName: subStreamName) : nil
        let mainURL = client.rtspURL(streamName: mainStreamName)
        controller.configure(
            subURL: subURL,
            mainURL: mainURL,
            subOnly: subOnly,
            muted: effectiveMuted,
            onPlaying: { live in onPlaying?(live) },
            // RTSP at 300 ms caching is genuinely sub-second — surface the same "Realtime" indicator
            // the WebRTC path lights up.
            onRealtime: { rt in onRealtimeChange?(rt) },
            onFailed: {
                onPlaying?(false)
                onRealtimeChange?(false)
                vlcFailed = true   // fall through to the HLS cascade for the rest of this view's life
            }
        )
        controller.start()
    }
}

// MARK: - Container view (VLC renders into a plain UIView; keep children filling it)

/// Hosts the sub/main video views and keeps them pinned to its bounds. VLC's `drawable` is any
/// UIView; SwiftUI resizes this container, and `layoutSubviews` keeps the video views matched to it
/// (VLC letterboxes within, preserving aspect — the tiles set the camera's aspect on the SwiftUI
/// side, so there are no bars).
final class VLCContainerView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        for sub in subviews { sub.frame = bounds }
    }
}

struct VLCVideoContainerRepresentable: UIViewRepresentable {
    let controller: VLCLiveController

    func makeUIView(context: Context) -> VLCContainerView {
        controller.container
    }

    func updateUIView(_ uiView: VLCContainerView, context: Context) {}
}

// MARK: - Controller (owns the players, does the sub-first → main swap)

/// Owns the VLC media player(s) for one tile/viewer and drives the sub-first → main-swap instant
/// open. Not `@MainActor` (VLCMediaPlayerDelegate is a plain Obj-C protocol); every callback hops
/// to main before touching players or published state, and every player call originates on main.
final class VLCLiveController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    /// The view VLC renders into. Stable for the controller's life so SwiftUI can hand it back from
    /// `makeUIView` without rebuilding.
    let container = VLCContainerView()

    private var subPlayer: VLCMediaPlayer?
    private var mainPlayer: VLCMediaPlayer?
    private var subView: UIView?
    private var mainView: UIView?

    private var subURL: URL?
    private var mainURL: URL?
    private var subOnly = false
    private var muted = true

    private var onPlaying: ((Bool) -> Void)?
    private var onRealtime: ((Bool) -> Void)?
    private var onFailed: (() -> Void)?

    private var started = false
    private var reportedLive = false
    private var swappedToMain = false
    /// Restart budget per phase before we give up and let the view fall back to HLS.
    private var subRetries = 0
    private var mainRetries = 0
    private static let maxRetries = 2
    /// Fires if NOTHING renders (not even the sub) within the grace window → fall back to HLS.
    private var failTask: Task<Void, Never>?
    private static let firstFrameGrace: UInt64 = 8_000_000_000  // 8 s

    func configure(
        subURL: URL?,
        mainURL: URL?,
        subOnly: Bool,
        muted: Bool,
        onPlaying: @escaping (Bool) -> Void,
        onRealtime: @escaping (Bool) -> Void,
        onFailed: @escaping () -> Void
    ) {
        self.subURL = subURL
        self.mainURL = mainURL
        self.subOnly = subOnly
        self.muted = muted
        self.onPlaying = onPlaying
        self.onRealtime = onRealtime
        self.onFailed = onFailed
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        reportedLive = false
        swappedToMain = false
        subRetries = 0
        mainRetries = 0

        // Sub first for the instant frame. The viewer then brings up main underneath-to-over and
        // swaps; a sub-less viewer goes straight to main.
        if let subURL {
            startSub(url: subURL)
            if !subOnly, mainURL != nil { startMain() }
        } else if let mainURL {
            startMain(url: mainURL)
        } else {
            fail(); return
        }

        armFailTimeout()
    }

    func stop() {
        started = false
        failTask?.cancel(); failTask = nil
        teardown(&subPlayer, &subView)
        teardown(&mainPlayer, &mainView)
        if reportedLive { onPlaying?(false); onRealtime?(false) }
        reportedLive = false
        swappedToMain = false
    }

    func setMuted(_ m: Bool) {
        muted = m
        applyMuted(subPlayer)
        applyMuted(mainPlayer)
    }

    // MARK: Player construction

    private func startSub(url: URL) {
        let view = UIView(frame: container.bounds)
        view.backgroundColor = .black
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // Sub sits at the bottom of the stack; main (when it arrives) is inserted above and revealed.
        container.insertSubview(view, at: 0)
        subView = view
        subPlayer = makePlayer(url: url, drawable: view)
        subPlayer?.play()
    }

    /// Overload that reads the stored `mainURL` (used from `start()` where we've already checked it).
    private func startMain() {
        guard let mainURL else { return }
        startMain(url: mainURL)
    }

    private func startMain(url: URL) {
        let view = UIView(frame: container.bounds)
        view.backgroundColor = .clear
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // If a sub is showing, keep main hidden until it actually renders, then cross-fade in — no
        // black flash during the swap.
        view.alpha = (subView == nil) ? 1 : 0
        container.addSubview(view)   // on top
        mainView = view
        mainPlayer = makePlayer(url: url, drawable: view)
        mainPlayer?.play()
    }

    private func makePlayer(url: URL, drawable: UIView) -> VLCMediaPlayer {
        // `--drop-late-frames` / `--skip-frames`: never let a bitrate spike (a car entering the 16 MP
        // frame) build latency — drop to stay live, the Reolink-style low-latency posture.
        // `--rtsp-tcp` ALSO here, not just as a media option: on some libvlc 3.x builds the access
        // option is only honored globally, and TCP-vs-UDP is the difference between clean 16 MP and
        // tearing — pass it both ways (harmless duplication).
        let player = VLCMediaPlayer(options: ["--rtsp-tcp", "--drop-late-frames", "--skip-frames"])
        player.delegate = self
        player.drawable = drawable
        player.media = makeMedia(url)
        applyMuted(player)
        return player
    }

    private func makeMedia(_ url: URL) -> VLCMedia {
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=300")  // small buffer → sub-second, not a fixed skew
        media.addOption(":rtsp-tcp")              // interleave RTP over the RTSP TCP (matches go2rtc)
        media.addOption(":clock-jitter=0")
        media.addOption(":clock-synchro=0")
        media.addOption(":drop-late-frames")
        media.addOption(":skip-frames")
        // Wall/grid tiles are permanently muted and never unmute — drop the audio track entirely so
        // a wall of them neither decodes audio nor fights over the shared audio session. The viewer
        // (not sub-only) keeps audio so its mute button can bring sound back without a reconnect.
        if subOnly { media.addOption(":no-audio") }
        return media
    }

    private func applyMuted(_ player: VLCMediaPlayer?) {
        // Volume 0 rather than the pause-decoding mute — the wall must stay silent but live.
        player?.audio?.volume = muted ? 0 : 100
    }

    // MARK: Delegate (VLC → main)

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        onMain { self.evaluate() }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        // Time advancing is the strongest proof real frames are being presented (a frozen/black
        // "playing" stream never advances) — re-evaluate so a laggy `hasVideoOut` still promotes.
        onMain { self.evaluate() }
    }

    private func evaluate() {
        guard started else { return }

        // Main taking over: only once it truly renders (state playing + a video output). Swapping on
        // "playing" alone can reveal a black main over a good sub — the frozen-black failure mode the
        // HLS path also guards against.
        if let main = mainPlayer, !swappedToMain, isRendering(main) {
            mainRetries = 0   // a confirmed picture refreshes this phase's retry budget
            swapToMain()
            markLive()
            return
        }

        // Sub live (the instant frame, and the final state on the wall).
        if !swappedToMain, let sub = subPlayer, isRendering(sub) {
            subRetries = 0
            markLive()
        }

        // Errors / unexpected ends → handle ONE phase per pass (each returns), so two dead players
        // can't both reach `fail()`, and each retry re-arms its own grace window.
        if let main = mainPlayer, main.state == .error || main.state == .ended {
            handleMainFailure(); return
        }
        if let sub = subPlayer, sub.state == .error || sub.state == .ended {
            handleSubFailure(); return
        }
    }

    private func isRendering(_ player: VLCMediaPlayer) -> Bool {
        player.state == .playing && player.hasVideoOut && player.videoSize != .zero
    }

    private func markLive() {
        guard !reportedLive else { return }
        reportedLive = true
        failTask?.cancel(); failTask = nil
        onPlaying?(true)
        onRealtime?(true)
    }

    private func swapToMain() {
        swappedToMain = true
        guard let mainView else { return }
        UIView.animate(withDuration: 0.25, animations: { mainView.alpha = 1 }, completion: { [weak self] _ in
            // Release the sub player once main is fully visible — two live decoders per viewer left
            // running is how a wall dies after a few opens.
            guard let self else { return }
            self.teardown(&self.subPlayer, &self.subView)
        })
    }

    // MARK: Failure handling

    private func handleSubFailure() {
        // If main already carries the picture, a dead sub is irrelevant.
        if swappedToMain { teardown(&subPlayer, &subView); return }
        guard subRetries < Self.maxRetries, let subURL else {
            // No sub and (for a sub-only tile) nothing else — give up to HLS. For a viewer, main may
            // still be coming; only fail if main isn't in play.
            if subOnly || mainPlayer == nil { fail() }
            teardown(&subPlayer, &subView)
            return
        }
        subRetries += 1
        teardown(&subPlayer, &subView)
        startSub(url: subURL)
        armFailTimeout()   // fresh grace so the retry isn't cut short by the original deadline
    }

    private func handleMainFailure() {
        guard mainRetries < Self.maxRetries, let mainURL else {
            // Main won't come. If the sub is still live we quietly stay on it (better than nothing);
            // otherwise fall back to HLS.
            teardown(&mainPlayer, &mainView)
            if !(subPlayer.map(isRendering) ?? false) { fail() }
            return
        }
        mainRetries += 1
        teardown(&mainPlayer, &mainView)
        startMain(url: mainURL)
        armFailTimeout()   // fresh grace (a no-op once we've reported live — the timeout guards on it)
    }

    private func fail() {
        let cb = onFailed
        stop()
        cb?()
    }

    private func armFailTimeout() {
        failTask?.cancel()
        failTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.firstFrameGrace)
            guard let self, !Task.isCancelled, self.started, !self.reportedLive else { return }
            self.fail()
        }
    }

    // MARK: Teardown

    private func teardown(_ player: inout VLCMediaPlayer?, _ view: inout UIView?) {
        if let p = player {
            p.delegate = nil
            if p.isPlaying { p.stop() }
            p.drawable = nil
        }
        player = nil
        view?.removeFromSuperview()
        view = nil
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    deinit {
        // deinit is nonisolated; VLC stop/teardown are thread-safe enough for a last-ditch cleanup,
        // but players are normally torn down on `stop()` from the main-thread lifecycle.
        subPlayer?.delegate = nil
        mainPlayer?.delegate = nil
        subPlayer?.stop()
        mainPlayer?.stop()
    }
}
