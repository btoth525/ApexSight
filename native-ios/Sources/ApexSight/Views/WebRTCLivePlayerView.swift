import Foundation
import SwiftUI
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

// MARK: - RTCClient

/// Owns one receive-only WebRTC playback connection to go2rtc (signaled via FrigateClient).
/// Non-trickle: gather candidates, POST the offer once, apply the complete answer. Publishes
/// the remote video track + a connection state the SwiftUI layer uses for live-vs-fallback.
@MainActor
final class RTCClient: NSObject, ObservableObject {
    enum State: Equatable { case connecting, connected, failed(String) }

    @Published private(set) var state: State = .connecting
    @Published private(set) var remoteVideoTrack: RTCVideoTrack?

    private var peerConnection: RTCPeerConnection?
    private var gatheringContinuation: CheckedContinuation<Void, Never>?
    private var didFinishGathering = false
    private var isTorndown = false

    private let camera: String
    private let useSub: Bool

    init(camera: String, useSub: Bool = false) {
        self.camera = camera
        self.useSub = useSub
        super.init()
    }

    func connect(client: FrigateClient) {
        let config = RTCConfiguration()
        // Empty/STUN-only is enough: go2rtc advertises its LAN host candidate in the answer,
        // and the phone gathers its own. The public STUN helps the secondary remote case.
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherOnce

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = WebRTCFactory.shared.peerConnection(with: config, constraints: constraints, delegate: self) else {
            state = .failed("Could not create peer connection")
            return
        }
        peerConnection = pc

        // Receive-only video (video-only keeps the audio session out of the live glance).
        let recvInit = RTCRtpTransceiverInit()
        recvInit.direction = .recvOnly
        pc.addTransceiver(of: .video, init: recvInit)

        Task { await negotiate(client: client) }
    }

    private func negotiate(client: FrigateClient) async {
        guard let pc = peerConnection else { return }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        do {
            let offer = try await makeOffer(pc, constraints)
            try await setLocal(pc, offer)
            // Non-trickle: wait for our own gathering (bounded) so the posted offer carries
            // the phone's host candidate; host<->host connects directly on the LAN.
            await waitForGathering(timeout: 2.0)
            guard !isTorndown else { return }

            let localSDP = pc.localDescription?.sdp ?? offer.sdp
            let answerSDP = try await client.webRTCAnswerSDP(camera: camera, sub: useSub, offerSDP: localSDP)
            guard !isTorndown else { return }

            try await setRemote(pc, RTCSessionDescription(type: .answer, sdp: answerSDP))
            // Connected state is reported by the peer-connection delegate, not here.
        } catch {
            if !isTorndown { state = .failed(error.localizedDescription) }
        }
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

    func teardown() {
        guard !isTorndown else { return }
        isTorndown = true
        resumeGathering()
        remoteVideoTrack = nil
        peerConnection?.close()
        peerConnection = nil
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
            guard let self, !self.isTorndown else { return }
            switch newState {
            case .connected: self.state = .connected
            case .failed, .closed: self.state = .failed("Connection lost")
            default: break
            }
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        guard let track = transceiver.receiver.track as? RTCVideoTrack else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.isTorndown, self.remoteVideoTrack == nil else { return }
            self.remoteVideoTrack = track
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.isTorndown, self.remoteVideoTrack == nil else { return }
            self.remoteVideoTrack = track
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

// MARK: - LiveVideoPlayerView (WebRTC primary → HLS fallback)

/// Live video with WebRTC as the INSTANT primary path and the proven HLS/MJPEG player as an
/// automatic fallback. WebRTC connects silently behind the cached snapshot; if it doesn't go
/// live within ~3s (or fails — e.g. off-LAN), we drop to `HLSLivePlayerView`, which itself
/// already cascades HLS → MJPEG. So this can only ADD a faster path, never reduce reliability.
struct LiveVideoPlayerView: View {
    @EnvironmentObject private var appState: AppState
    let camera: FrigateCamera
    var showControls: Bool = false
    var persistent: Bool = false
    var pipController: LivePiPController? = nil
    var onSingleTap: (() -> Void)? = nil
    var onPlaying: ((Bool) -> Void)? = nil

    @StateObject private var rtc: RTCClient
    @State private var fellBackToHLS = false
    @State private var connectTimer: Task<Void, Never>?
    @State private var started = false

    /// Cameras where WebRTC already failed this session — open straight on HLS so we don't
    /// pay the ~3s probe again (mirrors HLSLivePlayerView's own per-session memory).
    @MainActor private static var webRTCUnavailable: Set<String> = []

    init(camera: FrigateCamera, showControls: Bool = false, persistent: Bool = false,
         pipController: LivePiPController? = nil, onSingleTap: (() -> Void)? = nil,
         onPlaying: ((Bool) -> Void)? = nil) {
        self.camera = camera
        self.showControls = showControls
        self.persistent = persistent
        self.pipController = pipController
        self.onSingleTap = onSingleTap
        self.onPlaying = onPlaying
        _rtc = StateObject(wrappedValue: RTCClient(camera: camera.name))
    }

    private var isLive: Bool { rtc.state == .connected && rtc.remoteVideoTrack != nil }

    var body: some View {
        if fellBackToHLS || Self.webRTCUnavailable.contains(camera.name) {
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
            if let url = appState.client?.latestFrameURL(camera: camera.name) {
                RemoteImage(url: url, contentMode: .fit)
                    .opacity(isLive ? 0 : 1)
                    .animation(.easeOut(duration: 0.3), value: isLive)
                    .allowsHitTesting(false)
            }
            videoLayer
                .opacity(isLive ? 1 : 0)
                .animation(.easeIn(duration: 0.3), value: isLive)
        }
        .onAppear {
            guard !started else { return }
            started = true
            guard let client = appState.client else { fellBackToHLS = true; return }
            rtc.connect(client: client)
            startConnectTimer()
        }
        .onDisappear {
            if !persistent {
                connectTimer?.cancel(); connectTimer = nil
                rtc.teardown()
                started = false
            }
        }
        .onChange(of: rtc.state) { _, newState in
            switch newState {
            case .connected:
                connectTimer?.cancel(); connectTimer = nil
                onPlaying?(true)
            case .failed:
                goToHLS()
            default:
                break
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

    private func startConnectTimer() {
        connectTimer?.cancel()
        connectTimer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, !isLive else { return }
            goToHLS()
        }
    }

    private func goToHLS() {
        guard !fellBackToHLS else { return }
        connectTimer?.cancel(); connectTimer = nil
        Self.webRTCUnavailable.insert(camera.name)
        rtc.teardown()
        withAnimation(.easeIn(duration: 0.2)) { fellBackToHLS = true }
    }
}
