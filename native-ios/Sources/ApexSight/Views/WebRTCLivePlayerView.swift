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
/// Non-trickle: gather candidates, POST the offer once, apply the complete answer. Auto-retries
/// transient failures so live self-heals without any HLS fallback. Publishes the remote video
/// track + a connection state the SwiftUI layer renders.
@MainActor
final class RTCClient: NSObject, ObservableObject {
    enum State: Equatable { case connecting, connected, failed }

    @Published private(set) var state: State = .connecting
    @Published private(set) var remoteVideoTrack: RTCVideoTrack?

    private var peerConnection: RTCPeerConnection?
    private var gatheringContinuation: CheckedContinuation<Void, Never>?
    private var didFinishGathering = false
    private var isTorndown = false

    private let camera: String
    private let useSub: Bool
    private var client: FrigateClient?
    private var attempt = 0
    private let maxAttempts = 5
    private var retryTask: Task<Void, Never>?

    init(camera: String, useSub: Bool = false) {
        self.camera = camera
        self.useSub = useSub
        super.init()
    }

    func connect(client: FrigateClient) {
        self.client = client
        isTorndown = false
        attempt = 0
        state = .connecting
        openConnection()
    }

    /// Manual retry after we've given up (user tapped Retry).
    func retry() {
        guard client != nil else { return }
        retryTask?.cancel(); retryTask = nil
        isTorndown = false
        attempt = 0
        state = .connecting
        openConnection()
    }

    private func openConnection() {
        closePeer()
        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherOnce
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = WebRTCFactory.shared.peerConnection(with: config, constraints: constraints, delegate: self) else {
            handleFailure(); return
        }
        peerConnection = pc
        let recvInit = RTCRtpTransceiverInit()
        recvInit.direction = .recvOnly
        pc.addTransceiver(of: .video, init: recvInit)
        Task { await negotiate(pc) }
    }

    private func negotiate(_ pc: RTCPeerConnection) async {
        guard let client else { return }
        let c = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        do {
            let offer = try await makeOffer(pc, c)
            try await setLocal(pc, offer)
            await waitForGathering(timeout: 1.5)
            guard !isTorndown, peerConnection === pc else { return }
            let localSDP = pc.localDescription?.sdp ?? offer.sdp
            let answerSDP = try await client.webRTCAnswerSDP(camera: camera, sub: useSub, offerSDP: localSDP)
            guard !isTorndown, peerConnection === pc else { return }
            try await setRemote(pc, RTCSessionDescription(type: .answer, sdp: answerSDP))
        } catch {
            if !isTorndown, peerConnection === pc { handleFailure() }
        }
    }

    /// Retry a few times with a short backoff, then surface a terminal failure so the UI can
    /// show a Retry affordance. WebRTC reconnects sub-second, so retries are cheap.
    private func handleFailure() {
        guard !isTorndown else { return }
        closePeer()
        guard attempt < maxAttempts else { state = .failed; return }
        attempt += 1
        state = .connecting
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, !self.isTorndown, !Task.isCancelled else { return }
            self.retryTask = nil
            self.openConnection()
        }
    }

    private func closePeer() {
        resumeGathering()
        remoteVideoTrack = nil
        peerConnection?.close()
        peerConnection = nil
        didFinishGathering = false
    }

    func teardown() {
        guard !isTorndown else { return }
        isTorndown = true
        retryTask?.cancel(); retryTask = nil
        closePeer()
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
            case .connected: self.state = .connected; self.attempt = 0
            case .failed: self.handleFailure()
            default: break
            }
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        guard let track = transceiver.receiver.track as? RTCVideoTrack else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.isTorndown, pc === self.peerConnection, self.remoteVideoTrack == nil else { return }
            self.remoteVideoTrack = track
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.isTorndown, pc === self.peerConnection, self.remoteVideoTrack == nil else { return }
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

// MARK: - LiveVideoPlayerView (pure WebRTC)

/// Live video, WebRTC only — instant, Metal-rendered, hardware-decoded, like the big NVR apps.
/// It connects silently behind the cached snapshot (never black), auto-retries transient drops,
/// and shows a Retry affordance only if it truly can't reach the camera (e.g. off your LAN with
/// port 8555 not forwarded). Peers tear down on disappear and reconnect sub-second on return.
struct LiveVideoPlayerView: View {
    @EnvironmentObject private var appState: AppState
    let camera: FrigateCamera
    var showControls: Bool = false
    // Accepted for call-site compatibility (WebRTC reconnects instantly, and has no PiP).
    var persistent: Bool = false
    var pipController: LivePiPController? = nil
    var onSingleTap: (() -> Void)? = nil
    var onPlaying: ((Bool) -> Void)? = nil

    @StateObject private var rtc: RTCClient
    @State private var started = false

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
            if rtc.state == .failed, !isLive {
                retryOverlay
            }
        }
        .onAppear {
            guard !started else { return }
            started = true
            guard let client = appState.client else { return }
            rtc.connect(client: client)
        }
        .onDisappear {
            rtc.teardown()
            started = false
        }
        .onChange(of: rtc.state) { _, newState in
            onPlaying?(newState == .connected)
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

    private var retryOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.orange)
            Text("Can't reach this camera")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
            Button {
                Haptics.tap()
                rtc.retry()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.white, in: Capsule())
            }
        }
        .padding(20)
    }
}
