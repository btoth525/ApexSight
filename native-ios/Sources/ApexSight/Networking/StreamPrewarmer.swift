import Foundation
import WebRTC

/// One job: when the doorbell RINGS, start the doorbell's on-demand go2rtc encoder so the video is
/// already flowing by the time the call is answered. go2rtc runs one producer per stream and fans it
/// out to every consumer — so holding a minimal, **video-only**, recvonly WebRTC consumer during the
/// ring means the answer joins an already-running producer instead of cold-starting it.
///
/// Deliberately SEPARATE from `RealtimeVideoController`: it renders nothing, **never touches
/// `AVAudioSession`** (CallKit owns audio during a ring; touching it would court the `AURemoteIO`
/// crash), and never touches the controller's per-camera failure cap — so it can't block, slow, or
/// interfere with the real connection it warms. Fire-and-forget and fully guarded: worst case it
/// no-ops and the answer cold-starts exactly as before. Auto-tears-down after `ttl` (unanswered
/// ring), on answer/foreground it simply coexists for its few remaining seconds (one extra consumer
/// on an already-running producer is negligible). Reuses the one shared WebRTC factory.
///
/// This is intentionally the ONLY pre-warming in the app. Wall/away "keep-warm" was tried (builds
/// 196-199) and REMOVED: holding extra live streams competed with the camera actually being watched
/// and made opens SLOWER, especially away from home where everything shares the home uplink.
@MainActor
final class StreamPrewarmer: NSObject {
    static let shared = StreamPrewarmer()

    private final class Warm {
        let pc: RTCPeerConnection
        var gatherCont: CheckedContinuation<Void, Never>?
        var ttlTask: Task<Void, Never>?
        init(pc: RTCPeerConnection) { self.pc = pc }
    }
    private var warms: [String: Warm] = [:]

    private enum PrewarmError: Error { case noOffer }

    /// One-shot warm for an incoming doorbell ring. Reads the server from the App Group (so it works
    /// from a VoIP-woken background launch where `AppState` isn't up) and warms over the stored base
    /// URL with the full ICE path — any consumer warms the same producer. Auto-tears-down after
    /// `ttl` seconds.
    func warmForCall(camera: String, ttl: TimeInterval = 30) {
        guard warms[camera] == nil else { return }
        let defaults = UserDefaults(suiteName: ApexAppGroup.identifier)
        guard let base = defaults?.string(forKey: "apex.frigateBaseURL"),
              let baseURL = URL(string: base) else { return }
        let client = FrigateClient(baseURL: baseURL, token: SharedTokenStore.load())
        connect(camera: camera, client: client, ttl: ttl)
    }

    func stopAll() {
        guard !warms.isEmpty else { return }
        for cam in Array(warms.keys) { stop(camera: cam) }
        RealtimeVideoController.rtLog("prewarm: stopAll")
    }

    private func connect(camera: String, client: FrigateClient, ttl: TimeInterval) {
        Task { [weak self] in
            guard let self else { return }
            let config = RTCConfiguration()
            config.sdpSemantics = .unifiedPlan
            config.iceServers = await TurnSettings.iceServers()
            config.bundlePolicy = .maxBundle
            // Re-check after the await: a stopAll / duplicate could have landed in between.
            guard self.warms[camera] == nil else { return }
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            guard let pc = RealtimeVideoController.factory.peerConnection(with: config, constraints: constraints, delegate: self) else { return }
            let initt = RTCRtpTransceiverInit()
            initt.direction = .recvOnly
            pc.addTransceiver(of: .video, init: initt)   // video only — never audio
            let warm = Warm(pc: pc)
            self.warms[camera] = warm
            do {
                let offer = try await withCheckedThrowingContinuation { (c: CheckedContinuation<RTCSessionDescription, Error>) in
                    pc.offer(for: RTCMediaConstraints(
                        mandatoryConstraints: ["OfferToReceiveVideo": "true", "OfferToReceiveAudio": "false"],
                        optionalConstraints: nil)) { sdp, err in
                        if let sdp { c.resume(returning: sdp) } else { c.resume(throwing: err ?? PrewarmError.noOffer) }
                    }
                }
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    pc.setLocalDescription(offer) { err in if let err { c.resume(throwing: err) } else { c.resume() } }
                }
                // go2rtc's answer is non-trickle — the offer we POST must already carry candidates.
                await self.waitForGathering(warm)
                guard self.warms[camera] != nil else { pc.close(); return }
                let answerSDP = try await client.webRTCAnswer(source: camera, offerSDP: pc.localDescription?.sdp ?? offer.sdp)
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answerSDP)) { err in
                        if let err { c.resume(throwing: err) } else { c.resume() }
                    }
                }
                RealtimeVideoController.rtLog("prewarm: \(camera) negotiated (held, ttl \(Int(ttl))s)")
                if let held = self.warms[camera] {
                    held.ttlTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(ttl * 1_000_000_000))
                        await MainActor.run { self?.stop(camera: camera) }
                    }
                }
            } catch {
                RealtimeVideoController.rtLog("prewarm: \(camera) failed — \(error.localizedDescription)")
                self.stop(camera: camera)
            }
        }
    }

    private func waitForGathering(_ warm: Warm) async {
        if warm.pc.iceGatheringState == .complete { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in warm.gatherCont = c }
            }
            group.addTask { try? await Task.sleep(nanoseconds: 600_000_000) }
            await group.next()
            warm.gatherCont?.resume(); warm.gatherCont = nil
            group.cancelAll()
        }
    }

    private func stop(camera: String) {
        guard let warm = warms.removeValue(forKey: camera) else { return }
        warm.ttlTask?.cancel()
        warm.gatherCont?.resume(); warm.gatherCont = nil
        warm.pc.delegate = nil
        warm.pc.close()
    }
}

extension StreamPrewarmer: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        Task { @MainActor [weak self] in
            guard let self, let warm = self.warms.values.first(where: { $0.pc === pc }) else { return }
            warm.gatherCont?.resume(); warm.gatherCont = nil
        }
    }
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        RealtimeVideoController.rtLog("prewarm ice \(newState.rawValue)")
    }
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
