import AVFoundation
import WebRTC

/// Push-to-talk over Frigate/go2rtc's WebRTC backchannel: captures the mic and sends it to a
/// camera's speaker via `/api/go2rtc/api/webrtc?src=<camera>_twoway`.
///
/// Uses non-trickle ICE — we gather all local candidates before POSTing the offer and take
/// go2rtc's full answer back — which is what works through Frigate's HTTPS reverse proxy
/// both at home and remotely (remote also needs go2rtc `webrtc.candidates` + port 8555
/// forwarded; see the in-app note).
@MainActor
final class TwoWayTalkController: NSObject, ObservableObject {
    enum Status: Equatable { case idle, connecting, talking, failed(String) }
    @Published private(set) var status: Status = .idle

    // One factory for the process (initializing SSL repeatedly is wasteful/unsafe).
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    private var pc: RTCPeerConnection?
    private var micTrack: RTCAudioTrack?
    private var gatheringContinuation: CheckedContinuation<Void, Never>?

    var isActive: Bool { status == .connecting || status == .talking }

    /// Begin talking to `camera`. Resolves the mic permission, builds the peer connection,
    /// gathers ICE, exchanges SDP with go2rtc, and opens the audio.
    func start(cameraTwoWaySource: String, client: FrigateClient) async {
        guard !isActive else { return }
        status = .connecting

        guard await requestMicPermission() else {
            status = .failed("Microphone access denied")
            return
        }
        configureAudioSession()

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        config.bundlePolicy = .maxBundle
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            status = .failed("Couldn't create connection")
            return
        }
        self.pc = pc

        // Local mic track (send), and we also accept the camera's audio (receive) for full duplex.
        let micSource = Self.factory.audioSource(with: nil)
        let track = Self.factory.audioTrack(with: micSource, trackId: "apex-mic")
        pc.add(track, streamIds: ["apex-talk"])
        micTrack = track

        let offerConstraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "false"],
            optionalConstraints: nil
        )

        do {
            let offer = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RTCSessionDescription, Error>) in
                pc.offer(for: offerConstraints) { sdp, err in
                    if let sdp { cont.resume(returning: sdp) } else { cont.resume(throwing: err ?? TalkError.noOffer) }
                }
            }
            try await setLocal(offer, on: pc)
            await waitForIceGathering(pc)   // non-trickle: send the offer with candidates baked in

            let localSDP = pc.localDescription?.sdp ?? offer.sdp
            let answerSDP = try await client.webRTCAnswer(source: cameraTwoWaySource, offerSDP: localSDP)
            try await setRemote(RTCSessionDescription(type: .answer, sdp: answerSDP), on: pc)
            status = .talking
            Haptics.success()
        } catch {
            status = .failed(error.isCancellation ? "Cancelled" : error.localizedDescription)
            teardown()
        }
    }

    func stop() {
        teardown()
        status = .idle
    }

    // MARK: - Internals

    private func teardown() {
        micTrack = nil
        pc?.close()
        pc = nil
        gatheringContinuation?.resume()
        gatheringContinuation = nil
        deactivateAudioSession()
    }

    private func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in cont.resume(returning: granted) }
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat,
                                 options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? session.setActive(true)
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func setLocal(_ sdp: RTCSessionDescription, on pc: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { err in if let err { cont.resume(throwing: err) } else { cont.resume() } }
        }
    }

    private func setRemote(_ sdp: RTCSessionDescription, on pc: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { err in if let err { cont.resume(throwing: err) } else { cont.resume() } }
        }
    }

    /// Wait until ICE gathering completes (so the offer carries all candidates), capped so a
    /// stalled gather can't hang the press-to-talk.
    private func waitForIceGathering(_ pc: RTCPeerConnection) async {
        if pc.iceGatheringState == .complete { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    self.gatheringContinuation = cont
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
            await group.next()       // whichever finishes first (gather-complete or 2.5s cap)
            group.cancelAll()
        }
        gatheringContinuation = nil
    }

    enum TalkError: Error { case noOffer }
}

// MARK: - RTCPeerConnectionDelegate (required stubs; we only act on gathering + ICE state)

extension TwoWayTalkController: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        Task { @MainActor in
            self.gatheringContinuation?.resume()
            self.gatheringContinuation = nil
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed || newState == .disconnected || newState == .closed {
            Task { @MainActor in
                if self.status == .talking { self.status = .failed("Connection lost") }
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
