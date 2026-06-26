import Foundation
import Network
import SwiftUI
import UIKit
@preconcurrency import WebRTC

// MARK: - Shared factory

/// One process-wide factory — SSL + codec factories are heavy, so never rebuild per call.
enum WebRTCFactory {
    static let shared: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()
}

// MARK: - WebRTC availability (session + network aware)

/// Tracks whether WebRTC can currently reach the cameras. When a connection fails — almost
/// always because you're off the home LAN, so go2rtc's `8555` media candidate is unreachable —
/// we poison the WHOLE WebRTC path, not just that one camera. The reachability problem is
/// global, so the rest of the wall (and any camera opened later) skips the ~3s probe and goes
/// straight to HLS instead of each one re-discovering the same dead end.
///
/// A network change clears the poison: coming home onto Wi-Fi, or bringing up a VPN / Cloudflare
/// WARP tunnel, makes the LAN reachable again — so WebRTC is re-probed and instant live returns
/// without needing to force-quit the app.
@MainActor
final class WebRTCAvailability {
    static let shared = WebRTCAvailability()

    private var unavailable: Set<String> = []
    private var globallyUnavailable = false
    private let monitor = NWPathMonitor()
    private var sawInitialPath = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Skip the first path delivered at startup; only real changes should re-probe.
                guard self.sawInitialPath else { self.sawInitialPath = true; return }
                self.reset()
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.brandontoth.apexsight.webrtc.path"))
    }

    /// True when WebRTC should be skipped for this camera (this one already failed, or the
    /// whole path is poisoned for the current network).
    func isUnavailable(_ camera: String) -> Bool {
        globallyUnavailable || unavailable.contains(camera)
    }

    /// Record a WebRTC failure. A reachability failure (`global` — the peer never connected,
    /// e.g. you're off-LAN and can't reach the 8555 candidate) poisons the WHOLE path so the
    /// rest of the wall skips the probe. A per-camera failure (connected but no frame — a
    /// single broken/slow stream) marks only that camera, so healthy cameras stay on instant
    /// WebRTC instead of the whole wall being downgraded to HLS by one bad camera.
    func markUnavailable(_ camera: String, global: Bool) {
        unavailable.insert(camera)
        if global { globallyUnavailable = true }
    }

    /// Re-enable WebRTC (called on a network change). No-op when nothing is poisoned.
    func reset() {
        guard globallyUnavailable || !unavailable.isEmpty else { return }
        unavailable.removeAll()
        globallyUnavailable = false
    }
}

// MARK: - Connection establishment limiter

/// Caps how many grid tiles are *establishing* a WebRTC connection at once. Opening a peer
/// connection (offer + ICE gather + decoder spin-up) is the expensive part of first paint;
/// firing all of them simultaneously at launch is what makes the wall slow to come alive. The
/// snapshot already sits behind every tile, so tiles can upgrade to live progressively: a few
/// connect first, and as each renders its first frame (or fails over to HLS) the next tile's
/// slot opens. The full-screen viewer bypasses this entirely so a camera the user explicitly
/// opened never waits behind the wall.
@MainActor
final class WebRTCConnectionLimiter {
    static let shared = WebRTCConnectionLimiter()

    /// ~3 concurrent connects keeps several decoders warming without stampeding the CPU/network
    /// at launch. Tuned for the wall feeling instant while staying smooth.
    private let maxConcurrent = 3
    private var active = 0

    private struct Waiter { let id: UUID; let cont: CheckedContinuation<Bool, Never> }
    private var waiters: [Waiter] = []

    private init() {}

    /// Suspend until a connection slot is free. Returns `true` when a slot was granted (the
    /// caller MUST balance it with exactly one `release()`), or `false` if the awaiting task
    /// was cancelled while queued (no slot was taken — the caller must NOT release). Making the
    /// cancel path explicit stops a torn-down tile from orphaning its continuation in `waiters`
    /// (which would drift the slot accounting and stall the wall's progressive upgrade).
    func acquire() async -> Bool {
        if active < maxConcurrent {
            active += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                // Cancelled before we could park → don't take a slot.
                if Task.isCancelled {
                    cont.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: id, cont: cont))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(id) }
        }
    }

    /// Free a slot and let the next waiting tile begin connecting.
    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.cont.resume(returning: true)   // hands the just-freed slot straight to the next waiter
        } else if active > 0 {
            active -= 1
        }
    }

    /// A queued tile was torn down: remove its waiter and resume it with `false` so its task
    /// unblocks without consuming a slot. No-op if it was already granted a slot by `release()`.
    private func cancelWaiter(_ id: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        let w = waiters.remove(at: idx)
        w.cont.resume(returning: false)
    }
}

// MARK: - RTCClient

/// One receive-only WebRTC playback connection to go2rtc (signaled via FrigateClient).
/// Non-trickle: gather candidates, POST the offer once, apply the complete answer. Fails fast
/// so the view can fall back to HLS when WebRTC can't reach the camera (e.g. you're not on the
/// home LAN). Publishes the remote video track + a connection state.
@MainActor
final class RTCClient: NSObject, ObservableObject {
    enum State: Equatable { case connecting, connected, failed }

    @Published private(set) var state: State = .connecting
    @Published private(set) var remoteVideoTrack: RTCVideoTrack?
    /// Flips true only once a real decoded frame has actually rendered — NOT just when the
    /// track arrives. The UI waits for this before crossfading off the snapshot, so the live
    /// layer is never revealed while it's still black (which is what caused the flash).
    @Published private(set) var firstFrameRendered = false
    /// Whether this attempt's peer connection ever reached `.connected`. Distinguishes a true
    /// reachability failure (never connected → poison WebRTC globally) from a per-camera
    /// frame-timeout (connected but no video → only this camera falls back).
    private(set) var everConnected = false

    private var peerConnection: RTCPeerConnection?
    private var gatheringContinuation: CheckedContinuation<Void, Never>?
    private var didFinishGathering = false
    private var isTorndown = false
    private var frameSignal: FrameSignalRenderer?
    private var client: FrigateClient?
    private var watchdog: Task<Void, Never>?
    private var negotiateTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// True while this client is holding a connection slot from the shared limiter, so we
    /// release it exactly once (on first frame, fail, or teardown) and never over-release.
    private var holdsConnectSlot = false

    private let camera: String
    private let useSub: Bool
    /// When true (the full-screen viewer) this client skips the grid connect limiter, so a
    /// camera the user explicitly opened starts connecting immediately instead of queueing.
    private let bypassLimiter: Bool

    init(camera: String, useSub: Bool = false, bypassLimiter: Bool = false) {
        self.camera = camera
        self.useSub = useSub
        self.bypassLimiter = bypassLimiter
        super.init()
    }

    /// Connect once and then SURVIVE tab switches — safe to call on every `onAppear`. The
    /// connection only rebuilds when it has actually been torn down (e.g. app backgrounding),
    /// so returning to a kept-alive view is instant with the live stream already running.
    func start(client: FrigateClient) {
        guard !isTorndown else { return }
        self.client = client
        observeLifecycle()
        guard peerConnection == nil, connectTask == nil else { return }   // already connecting / connected
        buildConnection()
    }

    /// Acquire a connection slot (unless bypassing) and then open the peer connection. Gating
    /// here — not at the view layer — keeps callers simple: grid tiles upgrade to live a few at
    /// a time while the full-screen viewer connects immediately. The slot is released the moment
    /// the stream is live, fails, or is torn down, so the next queued tile starts.
    private func buildConnection() {
        guard client != nil, connectTask == nil, peerConnection == nil else { return }
        state = .connecting
        if bypassLimiter {
            openConnection()
            return
        }
        connectTask = Task { @MainActor [weak self] in
            let gotSlot = await WebRTCConnectionLimiter.shared.acquire()
            // Cancelled while queued → no slot was taken, nothing to release.
            guard gotSlot else { return }
            guard let self else { WebRTCConnectionLimiter.shared.release(); return }
            self.connectTask = nil
            // Torn down (or already rebuilt) while we waited for a slot — hand it back at once.
            guard !self.isTorndown, self.peerConnection == nil else {
                WebRTCConnectionLimiter.shared.release()
                return
            }
            self.holdsConnectSlot = true
            self.openConnection()
        }
    }

    /// Release the held connection slot exactly once. Safe to call repeatedly.
    private func releaseConnectSlot() {
        guard holdsConnectSlot else { return }
        holdsConnectSlot = false
        WebRTCConnectionLimiter.shared.release()
    }

    private func openConnection() {
        guard let client else { releaseConnectSlot(); return }
        firstFrameRendered = false
        everConnected = false
        state = .connecting
        didFinishGathering = false

        let config = RTCConfiguration()
        // No external STUN — go2rtc is on the same LAN, so host candidates connect
        // directly and STUN lookup to stun.l.google.com only delays ICE gathering.
        // When off-LAN, WebRTC will fail fast (no matching candidate) and fall through
        // to HLS in <2s instead of burning the full 1s gather cap on a STUN roundtrip.
        config.iceServers = []
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherOnce
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = WebRTCFactory.shared.peerConnection(with: config, constraints: constraints, delegate: self) else {
            state = .failed
            releaseConnectSlot()
            return
        }
        peerConnection = pc
        let recvInit = RTCRtpTransceiverInit()
        recvInit.direction = .recvOnly
        pc.addTransceiver(of: .video, init: recvInit)
        negotiateTask = Task { await negotiate(client: client, pc: pc) }
        startWatchdog()
    }

    /// Give up on WebRTC (so the view can fall back to HLS) if it can't deliver a real frame.
    /// First phase: if we haven't even connected in 2s, the path is dead (off-LAN, no route).
    /// Second phase: if connected but still no frame after another 1.5s, this camera is slow
    /// to key-frame — fall back rather than staying black.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, !isTorndown, !firstFrameRendered else { return }
            if state != .connected { markFailed(); return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, !isTorndown, !firstFrameRendered else { return }
            markFailed()
        }
    }

    /// Mark this attempt failed and immediately free any held connection slot so a queued
    /// grid tile can take it (rather than waiting for the view to drive the teardown).
    private func markFailed() {
        state = .failed
        releaseConnectSlot()
    }

    private func negotiate(client: FrigateClient, pc: RTCPeerConnection) async {
        let c = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        do {
            let offer = try await makeOffer(pc, c)
            try await setLocal(pc, offer)
            // Without STUN, host candidates are ready in <10ms. The 0.5s ceiling is a
            // safety net for unusual network stacks; in practice it fires at ~complete instantly.
            await waitForGathering(timeout: 0.5)
            guard !isTorndown, pc === peerConnection else { return }
            let localSDP = pc.localDescription?.sdp ?? offer.sdp
            let answerSDP = try await client.webRTCAnswerSDP(camera: camera, sub: useSub, offerSDP: localSDP)
            guard !isTorndown, pc === peerConnection else { return }
            try await setRemote(pc, RTCSessionDescription(type: .answer, sdp: answerSDP))
        } catch {
            if !isTorndown, pc === peerConnection { markFailed() }
        }
    }

    /// Adopt the incoming video track and attach a lightweight frame detector so we know the
    /// exact moment a real frame is on screen (see `firstFrameRendered`).
    private func attach(_ track: RTCVideoTrack) {
        guard remoteVideoTrack == nil else { return }
        remoteVideoTrack = track
        let signal = FrameSignalRenderer { [weak self] in
            Task { @MainActor in
                guard let self, !self.isTorndown, !self.firstFrameRendered else { return }
                self.firstFrameRendered = true
                // Live now — free the slot so the next queued tile can start connecting.
                self.releaseConnectSlot()
            }
        }
        track.add(signal)
        frameSignal = signal
    }

    /// Close the current peer connection but keep the object reusable (used on app
    /// backgrounding and before a rebuild). Nils `peerConnection` first so any late delegate
    /// callbacks from the old connection are ignored.
    private func resetConnection() {
        watchdog?.cancel(); watchdog = nil
        negotiateTask?.cancel(); negotiateTask = nil
        connectTask?.cancel(); connectTask = nil
        releaseConnectSlot()
        resumeGathering()
        if let frameSignal, let track = remoteVideoTrack { track.remove(frameSignal) }
        frameSignal = nil
        remoteVideoTrack = nil
        firstFrameRendered = false
        didFinishGathering = false
        let old = peerConnection
        peerConnection = nil
        old?.close()
    }

    func teardown() {
        guard !isTorndown else { return }
        isTorndown = true
        teardownLifecycle()
        resetConnection()
    }

    // MARK: App lifecycle — free the connection while suspended, rebuild on return

    private func observeLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isTorndown else { return }
                self.resetConnection()
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isTorndown, self.peerConnection == nil else { return }
                self.buildConnection()
            }
        })
    }

    private func teardownLifecycle() {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers.removeAll()
    }

    // MARK: Continuation-wrapped signaling (portable across WebRTC versions)

    private func makeOffer(_ pc: RTCPeerConnection, _ c: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { cont in
            pc.offer(for: c) { sdp, error in
                if let sdp { cont.resume(returning: sdp) }
                else { cont.resume(throwing: error ?? FrigateError.message("offer failed")) }
            }
        }
    }

    private func setLocal(_ pc: RTCPeerConnection, _ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    private func setRemote(_ pc: RTCPeerConnection, _ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
    }

    private func waitForGathering(timeout: TimeInterval) async {
        if didFinishGathering { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.gatheringContinuation = cont
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await MainActor.run { self?.resumeGathering() }
            }
        }
    }

    private func resumeGathering() {
        guard let cont = gatheringContinuation else { return }
        gatheringContinuation = nil
        cont.resume()
    }
}

// MARK: - RTCPeerConnectionDelegate (callbacks arrive on WebRTC's signaling thread)

extension RTCClient: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        Task { @MainActor [weak self] in
            self?.didFinishGathering = true
            self?.resumeGathering()
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, !self.isTorndown, pc === self.peerConnection else { return }
            switch newState {
            case .connected: self.everConnected = true; self.state = .connected
            case .failed, .closed: self.markFailed()
            default: break
            }
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        guard let track = transceiver.receiver.track as? RTCVideoTrack else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.isTorndown, pc === self.peerConnection else { return }
            self.attach(track)
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.isTorndown, pc === self.peerConnection else { return }
            self.attach(track)
        }
    }

    // Required-but-unused (non-trickle, unified-plan).
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

// MARK: - First-frame detector

/// A no-op WebRTC renderer attached alongside the on-screen Metal view. Its only job is to
/// fire once — the first time a real decoded frame flows through the track — so the UI can
/// wait for an actual frame before crossfading off the snapshot (eliminating the black flash
/// you'd otherwise get from revealing the video layer before it has anything to show).
final class FrameSignalRenderer: NSObject, RTCVideoRenderer {
    private let onFirstFrame: () -> Void
    private var fired = false

    init(onFirstFrame: @escaping () -> Void) { self.onFirstFrame = onFirstFrame }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard frame != nil, !fired else { return }
        fired = true
        onFirstFrame()
    }
}

// MARK: - WebRTCPlayerView (Metal renderer)

/// Renders an RTCVideoTrack via RTCMTLVideoView (Metal / hardware). Attaches the track when
/// it arrives, detaches on teardown so the renderer doesn't retain it.
struct WebRTCPlayerView: UIViewRepresentable {
    let track: RTCVideoTrack?
    var videoContentMode: UIView.ContentMode = .scaleAspectFit

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = videoContentMode
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        view.videoContentMode = videoContentMode
        if context.coordinator.attachedTrack !== track {
            context.coordinator.attachedTrack?.remove(view)
            track?.add(view)
            context.coordinator.attachedTrack = track
        }
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.attachedTrack?.remove(view)
        coordinator.attachedTrack = nil
    }

    final class Coordinator {
        weak var attachedTrack: RTCVideoTrack?
    }
}

// MARK: - LiveVideoPlayerView (WebRTC + HLS parallel race → MJPEG last resort)

/// Live video with a true parallel race: WebRTC and HLS both start at t=0. On the home LAN
/// WebRTC wins in <1 s (instant live) and the HLS warmup is discarded. Off the home LAN —
/// where go2rtc's 8555 port is unreachable — WebRTC fails in ~2 s, but HLS has been loading
/// that whole time and is often already playing the moment WebRTC gives up. This turns a
/// sequential 2 s + HLS-connect penalty into a parallel race where the user sees live video
/// as fast as the slower of the two streams can deliver — not the SUM. HLS itself cascades
/// HLS → MJPEG, so live ALWAYS loads everywhere.
struct LiveVideoPlayerView: View {
    @EnvironmentObject private var appState: AppState
    let camera: FrigateCamera
    var showControls: Bool = false
    var persistent: Bool = false
    /// Always false everywhere — full quality stream only, no sub-stream.
    var useSub: Bool = false
    /// Skip the shared grid connect limiter — the full-screen viewer passes true so a camera
    /// the user explicitly opened starts connecting immediately instead of queueing.
    var bypassConnectionLimit: Bool = false
    var pipController: LivePiPController? = nil
    var onSingleTap: (() -> Void)? = nil
    var onPlaying: ((Bool) -> Void)? = nil

    @StateObject private var rtc: RTCClient
    @State private var fellBackToHLS = false
    /// True while the parallel HLS layer is mounted. Flips to false when WebRTC delivers its
    /// first frame (WebRTC won — stop the HLS warmup to save bandwidth). Stays true forever
    /// when WebRTC fails so the already-loading HLS layer transitions to visible without
    /// restarting from scratch.
    @State private var hlsRaceActive = true
    /// Tracks whether HLS has reported playing. Not propagated to `onPlaying` while HLS is
    /// hidden behind the WebRTC layer — only surfaced once HLS becomes the visible primary.
    @State private var hlsIsPlaying = false

    init(camera: FrigateCamera, showControls: Bool = false, persistent: Bool = false,
         useSub: Bool = false, bypassConnectionLimit: Bool = false,
         pipController: LivePiPController? = nil,
         onSingleTap: (() -> Void)? = nil, onPlaying: ((Bool) -> Void)? = nil) {
        self.camera = camera
        self.showControls = showControls
        self.persistent = persistent
        self.useSub = useSub
        self.bypassConnectionLimit = bypassConnectionLimit
        self.pipController = pipController
        self.onSingleTap = onSingleTap
        self.onPlaying = onPlaying
        _rtc = StateObject(wrappedValue: RTCClient(camera: camera.name, useSub: useSub, bypassLimiter: bypassConnectionLimit))
    }

    /// True when WebRTC should be skipped: it already failed for this camera, or a prior
    /// camera poisoned the whole path (global off-LAN detection).
    private var skipWebRTC: Bool {
        fellBackToHLS || WebRTCAvailability.shared.isUnavailable(camera.name)
    }

    private var isLive: Bool { rtc.firstFrameRendered }

    var body: some View {
        ZStack {
            // HLS: pre-loading silently from t=0 alongside WebRTC.
            // • Hidden (opacity 0) while WebRTC is still racing — no visible gap.
            // • Visible the moment WebRTC fails or was already known-unavailable.
            // • Only unmounted when WebRTC wins (firstFrameRendered), which stops it
            //   to save bandwidth. The same instance survives the hidden→visible
            //   transition so HLS never restarts mid-connection when WebRTC fails.
            if hlsRaceActive {
                HLSLivePlayerView(
                    camera: camera,
                    showControls: showControls,
                    persistent: skipWebRTC ? persistent : false,
                    pipController: skipWebRTC ? pipController : nil,
                    onSingleTap: skipWebRTC ? onSingleTap : nil,
                    onPlaying: { playing in
                        hlsIsPlaying = playing
                        // Only forward the playing state while HLS is the VISIBLE player —
                        // not while it is warming up behind the WebRTC layer.
                        if skipWebRTC { onPlaying?(playing) }
                    }
                )
                .opacity(skipWebRTC ? 1 : 0)
                .allowsHitTesting(skipWebRTC)
            }

            // WebRTC: on top while it still has a chance. Removed once it loses.
            if !skipWebRTC {
                webRTCContent
            }
        }
        // The instant WebRTC gives up, surface HLS's buffered playing state so the caller
        // sees "Live" immediately if HLS was already playing behind the scenes.
        .onChange(of: skipWebRTC) { _, nowSkipping in
            if nowSkipping { onPlaying?(hlsIsPlaying) }
        }
    }

    private var webRTCContent: some View {
        ZStack {
            Color.black
            // Snapshot placeholder — shown until the first real frame renders. Birdseye has
            // no `latest.jpg` endpoint, so skip the network request and show ConnectingHint.
            if camera.name != "birdseye",
               let url = appState.client?.latestFrameURL(camera: camera.name) {
                RemoteImage(url: url, contentMode: .fit)
                    .allowsHitTesting(false)
            } else if camera.name == "birdseye", !isLive {
                ConnectingHint()
                    .allowsHitTesting(false)
            }
            videoLayer
                .opacity(isLive ? 1 : 0)
                .animation(.easeInOut(duration: 0.28), value: isLive)
        }
        .onAppear {
            guard let client = appState.client else { fellBackToHLS = true; return }
            rtc.start(client: client)
        }
        .onDisappear {
            if !persistent { rtc.teardown() }
        }
        .onChange(of: rtc.state) { _, newState in
            if newState == .failed { goToHLS() }
        }
        .onChange(of: rtc.firstFrameRendered) { _, rendered in
            if rendered {
                onPlaying?(true)
                // WebRTC won the race — stop the parallel HLS warmup to save bandwidth.
                hlsRaceActive = false
            }
        }
    }

    @ViewBuilder
    private var videoLayer: some View {
        let player = WebRTCPlayerView(track: rtc.remoteVideoTrack)
        if showControls {
            ZoomableScrollView(onSingleTap: onSingleTap) { player }
        } else {
            player
        }
    }

    private func goToHLS() {
        guard !fellBackToHLS else { return }
        // Never connected → reachability failure (off-LAN) → poison WebRTC globally so the
        // rest of the wall skips the probe. Connected but no frame → just this camera.
        WebRTCAvailability.shared.markUnavailable(camera.name, global: !rtc.everConnected)
        rtc.teardown()
        withAnimation(.easeIn(duration: 0.2)) { fellBackToHLS = true }
        // hlsRaceActive stays true — the HLS layer was pre-loading and now becomes the
        // visible primary without restarting, giving the user the fastest possible transition.
    }
}
