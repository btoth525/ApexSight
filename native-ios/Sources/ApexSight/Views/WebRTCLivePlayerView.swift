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
    private var lifecycleObservers: [NSObjectProtocol] = []

    private let camera: String
    private let useSub: Bool

    init(camera: String, useSub: Bool = false) {
        self.camera = camera
        self.useSub = useSub
        super.init()
    }

    /// Connect once and then SURVIVE tab switches — safe to call on every `onAppear`. The
    /// connection only rebuilds when it has actually been torn down (e.g. app backgrounding),
    /// so returning to a kept-alive view is instant with the live stream already running.
    func start(client: FrigateClient) {
        guard !isTorndown else { return }
        self.client = client
        observeLifecycle()
        guard peerConnection == nil else { return }   // already connecting / connected
        buildConnection()
    }

    private func buildConnection() {
        guard let client else { return }
        firstFrameRendered = false
        everConnected = false
        state = .connecting
        didFinishGathering = false

        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherOnce
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = WebRTCFactory.shared.peerConnection(with: config, constraints: constraints, delegate: self) else {
            state = .failed
            return
        }
        peerConnection = pc
        let recvInit = RTCRtpTransceiverInit()
        recvInit.direction = .recvOnly
        pc.addTransceiver(of: .video, init: recvInit)
        negotiateTask = Task { await negotiate(client: client, pc: pc) }
        startWatchdog()
    }

    /// Give up on WebRTC (so the view can fall back to HLS) if it can't deliver a real frame:
    /// fast when we never even connect (off-LAN), patient once connected (a doorbell may wait
    /// a beat for a keyframe).
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, !isTorndown, !firstFrameRendered else { return }
            if state != .connected { state = .failed; return }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled, !isTorndown, !firstFrameRendered else { return }
            state = .failed
        }
    }

    private func negotiate(client: FrigateClient, pc: RTCPeerConnection) async {
        let c = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        do {
            let offer = try await makeOffer(pc, c)
            try await setLocal(pc, offer)
            await waitForGathering(timeout: 2.0)
            guard !isTorndown, pc === peerConnection else { return }
            let localSDP = pc.localDescription?.sdp ?? offer.sdp
            let answerSDP = try await client.webRTCAnswerSDP(camera: camera, sub: useSub, offerSDP: localSDP)
            guard !isTorndown, pc === peerConnection else { return }
            try await setRemote(pc, RTCSessionDescription(type: .answer, sdp: answerSDP))
        } catch {
            if !isTorndown, pc === peerConnection { state = .failed }
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
            case .failed, .closed: self.state = .failed
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

// MARK: - LiveVideoPlayerView (WebRTC primary → HLS/MJPEG fallback)

/// Live video: WebRTC as the INSTANT primary path, with automatic fallback to the proven
/// HLS/MJPEG player when WebRTC can't connect (e.g. you're not on the home LAN, so the phone
/// can't reach go2rtc's 8555 candidate). WebRTC connects silently behind the cached snapshot;
/// if it isn't live within ~3s (or fails), we drop to HLSLivePlayerView — which itself cascades
/// HLS → MJPEG. So live ALWAYS loads: instant at home, reliable everywhere else.
struct LiveVideoPlayerView: View {
    @EnvironmentObject private var appState: AppState
    let camera: FrigateCamera
    var showControls: Bool = false
    var persistent: Bool = false
    /// Use the low-res sub-stream — grid tiles pass true so several can stream smoothly at
    /// once; the full-screen view uses the main (high-res) stream.
    var useSub: Bool = false
    var pipController: LivePiPController? = nil
    var onSingleTap: (() -> Void)? = nil
    var onPlaying: ((Bool) -> Void)? = nil

    @StateObject private var rtc: RTCClient
    @State private var fellBackToHLS = false

    init(camera: FrigateCamera, showControls: Bool = false, persistent: Bool = false,
         useSub: Bool = false, pipController: LivePiPController? = nil,
         onSingleTap: (() -> Void)? = nil, onPlaying: ((Bool) -> Void)? = nil) {
        self.camera = camera
        self.showControls = showControls
        self.persistent = persistent
        self.useSub = useSub
        self.pipController = pipController
        self.onSingleTap = onSingleTap
        self.onPlaying = onPlaying
        _rtc = StateObject(wrappedValue: RTCClient(camera: camera.name, useSub: useSub))
    }

    /// "Live" means a real frame is actually on screen — not merely that the track arrived.
    /// Gating the snapshot→video crossfade on this is what removes the black flash.
    private var isLive: Bool { rtc.firstFrameRendered }

    var body: some View {
        if fellBackToHLS || WebRTCAvailability.shared.isUnavailable(camera.name) {
            HLSLivePlayerView(
                camera: camera, showControls: showControls, persistent: persistent,
                pipController: pipController, onSingleTap: onSingleTap, onPlaying: onPlaying
            )
        } else {
            webRTCContent
        }
    }

    private var webRTCContent: some View {
        ZStack {
            Color.black
            // Snapshot stays put UNDERNEATH the video — we never fade it out. The live layer
            // fades IN on top of it only once a real frame has rendered, so there's never a
            // black gap or pop between the snapshot and live video.
            if let url = appState.client?.latestFrameURL(camera: camera.name) {
                RemoteImage(url: url, contentMode: .fit)
                    .allowsHitTesting(false)
            }
            videoLayer
                .opacity(isLive ? 1 : 0)
                .animation(.easeInOut(duration: 0.28), value: isLive)
        }
        // Connect once; the connection owns its own timeout + reconnect lifecycle. On a
        // persistent surface (the Cameras tab) we DON'T tear down when the view disappears,
        // so switching tabs and coming back leaves the stream already running — no reconnect.
        .onAppear {
            guard let client = appState.client else { fellBackToHLS = true; return }
            rtc.start(client: client)
        }
        .onDisappear {
            if !persistent { rtc.teardown() }
        }
        // The connection reports .failed when it can't reach the camera or never delivers a
        // frame in time — that's our cue to fall back to HLS.
        .onChange(of: rtc.state) { _, newState in
            if newState == .failed { goToHLS() }
        }
        // Report "playing" only when a real frame has rendered, not when the connection opens.
        .onChange(of: rtc.firstFrameRendered) { _, rendered in
            if rendered { onPlaying?(true) }
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
    }
}
