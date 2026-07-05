import AVFoundation
import UIKit
import WebRTC

/// Sub-second live video over go2rtc's WebRTC — the same signaling path two-way talk already
/// uses, receiving the camera's VIDEO instead of sending mic audio. Tries fast and fails
/// quietly: the HLS player keeps running underneath, so a camera that can't do WebRTC (HEVC
/// main stream, remote with no media path through the tunnel) just stays on HLS with zero
/// user-visible cost. Video-only by design — unmuting switches the viewer back to HLS for
/// audio, which keeps WebRTC's audio-session machinery entirely out of the picture (and away
/// from the talk feature's).
@MainActor
final class RealtimeVideoController: NSObject, ObservableObject {
    enum State: Equatable { case idle, connecting, live, failed }

    @Published private(set) var state: State = .idle
    @Published private(set) var videoTrack: RTCVideoTrack?

    // One factory per process (shared pattern with TwoWayTalkController).
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    private var pc: RTCPeerConnection?
    private var gatheringContinuation: CheckedContinuation<Void, Never>?
    private var startTask: Task<Void, Never>?
    /// Resolved true by the first RENDERED frame, false by the per-attempt timeout / ICE failure.
    private var firstFrameContinuation: CheckedContinuation<Bool, Never>?
    private var attemptWatchdog: Task<Void, Never>?
    private var bgObserver: NSObjectProtocol?
    private(set) var isSuspendedByBackground = false
    /// Per-camera failure count — a camera whose sources all fail (no H264 path, no media route)
    /// stops being retried after 2 rounds this session instead of hammering go2rtc on every
    /// mute-toggle/appear. Cleared by a successful first frame. Keyed by the primary source.
    private var failures: [String: Int] = [:]

    override init() {
        super.init()
        // Realtime video has no PiP story — stop on background and let the HLS player (still
        // running underneath) own the background/auto-PiP behavior it already handles.
        bgObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .connecting || self.state == .live else { return }
                self.isSuspendedByBackground = true
                self.stop()
            }
        }
    }

    deinit {
        if let bgObserver { NotificationCenter.default.removeObserver(bgObserver) }
    }

    /// Try `sources` in order (e.g. `["Backyard_Wide", "Backyard_Wide_sub"]`) until one renders a
    /// frame — so an HEVC MAIN stream (iOS can't WebRTC-decode) automatically falls to the H264
    /// SUB stream and still gets sub-second live.
    func start(sources: [String], client: FrigateClient) {
        Self.rtLog("start requested: \(sources) (state=\(state))")
        guard state == .idle || state == .failed else { return }
        let key = sources.first ?? ""
        guard failures[key, default: 0] < 2 else { Self.rtLog("start refused: failure cap"); return }
        isSuspendedByBackground = false
        primaryKey = key
        state = .connecting
        startTask = Task { [weak self] in
            await self?.cascade(sources: sources, client: client)
            self?.startTask = nil
        }
    }

    private var primaryKey = ""

    func stop() {
        startTask?.cancel(); startTask = nil
        teardown()
        state = .idle
    }

    /// Called by the renderer when the first real frame lands — THIS is "live", not ICE state
    /// (a connection can succeed while the video codec is undecodable).
    func noteFirstFrame() {
        resolveAttempt(true)
    }

    // MARK: - Connect

    /// Step-by-step diagnostics (visible in Console/`log stream`) — realtime fails SILENTLY by
    /// design, so this is the only way to see where an attempt dies in the field.
    nonisolated static func rtLog(_ message: String) {
        #if DEBUG
        fputs("[realtime] \(message)\n", stderr)   // stderr = unbuffered, always reaches the console
        #endif
    }

    private func cascade(sources: [String], client: FrigateClient) async {
        for source in sources {
            if Task.isCancelled { return }
            Self.rtLog("attempt \(source)")
            let rendered = await attempt(source: source, client: client)
            Self.rtLog("attempt \(source) → \(rendered ? "RENDERED ✅" : "no frame ❌")")
            if rendered {
                failures[primaryKey] = 0
                state = .live
                return
            }
            teardown()   // clean up before trying the next source
            if Task.isCancelled { return }
        }
        failures[primaryKey, default: 0] += 1
        if !Task.isCancelled { state = .failed }
    }

    /// One source: negotiate, then wait for a rendered frame (true) or timeout/failure (false).
    private func attempt(source: String, client: FrigateClient) async -> Bool {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = await TurnSettings.iceServers()
        config.bundlePolicy = .maxBundle
        config.iceTransportPolicy = .all
        guard !Task.isCancelled else { return false }

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            return false
        }
        self.pc = pc
        let initt = RTCRtpTransceiverInit()
        initt.direction = .recvOnly
        let videoTransceiver = pc.addTransceiver(of: .video, init: initt)

        do {
            let offerConstraints = RTCMediaConstraints(
                mandatoryConstraints: ["OfferToReceiveVideo": "true", "OfferToReceiveAudio": "false"],
                optionalConstraints: nil
            )
            let offer = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RTCSessionDescription, Error>) in
                pc.offer(for: offerConstraints) { sdp, err in
                    if let sdp { cont.resume(returning: sdp) } else { cont.resume(throwing: err ?? RTError.noOffer) }
                }
            }
            try Task.checkCancellation()
            try await set(local: offer, on: pc)
            await waitForIceGathering(pc)
            try Task.checkCancellation()
            let localSDP = pc.localDescription?.sdp ?? offer.sdp
            Self.rtLog("offer ready (\(localSDP.count)B, \(localSDP.components(separatedBy: "a=candidate").count - 1) candidates)")
            let answerSDP = try await client.webRTCAnswer(source: source, offerSDP: localSDP)
            Self.rtLog("answer received (\(answerSDP.count)B, \(answerSDP.components(separatedBy: "a=candidate").count - 1) candidates, video=\(answerSDP.contains("m=video")))")
            try Task.checkCancellation()
            try await set(remote: RTCSessionDescription(type: .answer, sdp: answerSDP), on: pc)
        } catch {
            Self.rtLog("negotiation error: \(error.localizedDescription)")
            return false
        }

        // Attach the receiver's video track to the renderer directly — the transceiver we added
        // owns it after negotiation. (Relying on the `didStartReceivingOn` delegate was the bug:
        // it doesn't fire reliably for a pre-added recvonly transceiver, so a frame never reached
        // the renderer and every attempt timed out.)
        if let track = videoTransceiver?.receiver.track as? RTCVideoTrack {
            Self.rtLog("video track attached from transceiver")
            videoTrack = track
        } else {
            Self.rtLog("no video track on transceiver receiver (waiting on delegate)")
        }

        // Await the first RENDERED frame or a 4s timeout — an HEVC track connects but never
        // paints, which this catches.
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            firstFrameContinuation = cont
            attemptWatchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await MainActor.run { self?.resolveAttempt(false) }
            }
        }
    }

    /// Resolve the in-flight attempt exactly once (first frame → true, timeout/ICE-fail → false).
    private func resolveAttempt(_ rendered: Bool) {
        attemptWatchdog?.cancel(); attemptWatchdog = nil
        guard let cont = firstFrameContinuation else { return }
        firstFrameContinuation = nil
        cont.resume(returning: rendered)
    }

    private func teardown() {
        attemptWatchdog?.cancel(); attemptWatchdog = nil
        // Don't strand a suspended attempt — resolve it false before tearing the pc down.
        if let cont = firstFrameContinuation { firstFrameContinuation = nil; cont.resume(returning: false) }
        videoTrack = nil
        pc?.delegate = nil
        pc?.close()
        pc = nil
        gatheringContinuation?.resume()
        gatheringContinuation = nil
    }

    private func set(local sdp: RTCSessionDescription, on pc: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { err in if let err { cont.resume(throwing: err) } else { cont.resume() } }
        }
    }

    private func set(remote sdp: RTCSessionDescription, on pc: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { err in if let err { cont.resume(throwing: err) } else { cont.resume() } }
        }
    }

    private func waitForIceGathering(_ pc: RTCPeerConnection) async {
        if pc.iceGatheringState == .complete { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    self.gatheringContinuation = cont
                }
            }
            group.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            await group.next()
            gatheringContinuation?.resume()
            gatheringContinuation = nil
            group.cancelAll()
        }
    }

    enum RTError: Error { case noOffer }
}

// MARK: - RTCPeerConnectionDelegate

extension RealtimeVideoController: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        Task { @MainActor [weak self] in
            self?.gatheringContinuation?.resume()
            self?.gatheringContinuation = nil
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        guard let track = transceiver.receiver.track as? RTCVideoTrack else { return }
        Task { @MainActor [weak self] in
            guard let self, self.state == .connecting else { return }
            if self.videoTrack == nil { self.videoTrack = track }
        }
    }

    // Backup track path — some negotiations surface the receiver here rather than via the
    // transceiver we pre-added. Either way the renderer gets attached.
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        Task { @MainActor [weak self] in
            guard let self, self.state == .connecting else { return }
            if self.videoTrack == nil { self.videoTrack = track }
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Self.rtLog("ice state \(newState.rawValue) (0=new 1=checking 2=connected 3=completed 4=failed 5=disconnected 6=closed)")
        if newState == .failed || newState == .closed {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.state == .connecting {
                    // Fail THIS attempt so the cascade can try the next source (or give up).
                    self.resolveAttempt(false)
                } else if self.state == .live {
                    // A live session dropped — fall back to HLS (still running underneath).
                    self.state = .failed
                    self.teardown()
                }
            }
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

// MARK: - Renderer view

import SwiftUI

/// Metal-backed WebRTC video renderer. Reports the first real frame so the host only fades the
/// realtime layer in once there's actually a picture (never a black overlay).
struct RealtimeVideoView: UIViewRepresentable {
    let track: RTCVideoTrack
    var onFirstFrame: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFirstFrame: onFirstFrame) }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFit
        view.delegate = context.coordinator
        track.add(view)
        context.coordinator.attached = track
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        if context.coordinator.attached !== track {
            context.coordinator.attached?.remove(view)
            track.add(view)
            context.coordinator.attached = track
        }
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.attached?.remove(view)
        coordinator.attached = nil
    }

    final class Coordinator: NSObject, RTCVideoViewDelegate {
        var attached: RTCVideoTrack?
        private let onFirstFrame: @MainActor () -> Void
        private var fired = false

        init(onFirstFrame: @escaping @MainActor () -> Void) {
            self.onFirstFrame = onFirstFrame
        }

        func videoView(_ videoView: any RTCVideoRenderer, didChangeVideoSize size: CGSize) {
            guard !fired, size.width > 0 else { return }
            fired = true
            Task { @MainActor in self.onFirstFrame() }
        }
    }
}
