import Foundation
import WebRTC

/// The set of cameras whose live stream cold-starts slowly (an on-demand server-side re-encode —
/// the Scrypted-bridged doorbell, a 4K-HEVC camera iOS can't WebRTC-decode directly). Learned at
/// runtime from real first-frame timings (see `RealtimeVideoController.resolveAttempt`) rather than
/// hard-coded, so it adapts if cameras are added/renamed. Stored in the App Group so a VoIP-woken
/// launch could read it too. Sticky within a server; reset when the server changes / on sign-out.
enum SlowStartCameraStore {
    private static let key = "apex.slowStartCameras"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: ApexAppGroup.identifier) }

    static var all: Set<String> {
        Set(defaults?.stringArray(forKey: key) ?? [])
    }

    static func record(_ camera: String) {
        var set = all
        guard !set.contains(camera) else { return }
        set.insert(camera)
        defaults?.set(Array(set), forKey: key)
        RealtimeVideoController.rtLog("slow-start learned: \(camera) (warm list = \(set.sorted()))")
    }

    static func reset() {
        defaults?.removeObject(forKey: key)
    }
}

/// Keeps go2rtc's on-demand `ffmpeg` re-encode HOT for specific cameras by holding a minimal,
/// **video-only**, recvonly WebRTC consumer open. go2rtc runs ONE producer per stream and fans it
/// out to every consumer, lingering only briefly after the last leaves — so a held consumer keeps
/// the encoder running, and the real tap/answer then joins an already-running producer and paints
/// in a fraction of the cold-start time.
///
/// Deliberately SEPARATE from `RealtimeVideoController`: success here is "negotiated + ICE trying"
/// (a consumer is subscribed → the producer stays up), NOT "frame rendered". It renders nothing,
/// **never touches `AVAudioSession`** (activating audio here would court the `AURemoteIO` crash and
/// fight CallKit), and **never touches the controller's per-camera failure cap** — so it can't
/// block, slow, or interfere with the real connection it's warming. Reuses the one shared
/// `RealtimeVideoController.factory` so there's a single heavy WebRTC factory per process.
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

    /// Warm each of `cameras` (idempotent — one already warm is left alone). Held until `stopAll`.
    /// `directLAN` mirrors the real path: host-only on the LAN (no TURN fetch/relay), full ICE off it.
    func warm(cameras: [String], client: FrigateClient, directLAN: Bool) {
        for cam in cameras where warms[cam] == nil {
            connect(camera: cam, client: client, directLAN: directLAN, ttl: nil)
        }
        // Drop warms no longer wanted (e.g. the slow-set shrank on a server switch).
        for cam in warms.keys where !cameras.contains(cam) { stop(camera: cam) }
    }

    /// One-shot warm for an incoming doorbell ring. Reads the server from the App Group (so it works
    /// from a VoIP-woken background launch where `AppState` isn't up), warms over the remote URL with
    /// the full ICE path — we can't know or probe home-vs-away inside the ring window, and ANY
    /// consumer warms the same producer — and auto-tears-down after `ttl` if the call is never
    /// answered. Fire-and-forget and fully guarded: worst case it no-ops and the answer cold-starts
    /// exactly as before, so it can never harm the (required) CallKit reporting that already ran.
    func warmForCall(camera: String, ttl: TimeInterval = 30) {
        guard warms[camera] == nil else { return }
        let defaults = UserDefaults(suiteName: ApexAppGroup.identifier)
        guard let base = defaults?.string(forKey: "apex.frigateBaseURL"),
              let baseURL = URL(string: base) else { return }
        let client = FrigateClient(baseURL: baseURL, token: SharedTokenStore.load())
        connect(camera: camera, client: client, directLAN: false, ttl: ttl)
    }

    func stopAll() {
        guard !warms.isEmpty else { return }
        for cam in Array(warms.keys) { stop(camera: cam) }
        RealtimeVideoController.rtLog("prewarm: stopAll")
    }

    var warmedCameras: [String] { Array(warms.keys).sorted() }

    private func connect(camera: String, client: FrigateClient, directLAN: Bool, ttl: TimeInterval?) {
        Task { [weak self] in
            guard let self else { return }
            let config = RTCConfiguration()
            config.sdpSemantics = .unifiedPlan
            config.iceServers = directLAN ? [] : await TurnSettings.iceServers()
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
                // go2rtc's answer is non-trickle — the offer we POST must already carry candidates,
                // so wait for gathering (host candidates land in ms on the LAN; capped for TURN).
                await self.waitForGathering(warm)
                guard self.warms[camera] != nil else { pc.close(); return }
                let answerSDP = try await client.webRTCAnswer(source: camera, offerSDP: pc.localDescription?.sdp ?? offer.sdp)
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answerSDP)) { err in
                        if let err { c.resume(throwing: err) } else { c.resume() }
                    }
                }
                RealtimeVideoController.rtLog("prewarm: \(camera) negotiated (held\(ttl != nil ? ", ttl \(Int(ttl!))s" : ""))")
                if let ttl, let held = self.warms[camera] {
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
