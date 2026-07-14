import AVFoundation
import UIKit
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
    private var bgObserver: NSObjectProtocol?
    /// Fails an attempt that never connects (remote with no reachable media path) instead of
    /// spinning forever, with copy that points at the actual fix (TURN on the relay).
    private var connectWatchdog: Task<Void, Never>?
    /// The in-flight connect. Held so a quick release (`stop()`) can CANCEL it — otherwise a
    /// press released before the SDP handshake finishes would let the mic + peer connection open
    /// after the finger is already up, with no release event coming, leaving a stuck hot mic.
    private var startTask: Task<Void, Never>?
    /// Bumped by every begin()/stop(). A connect() attempt captures its value and checks it at each
    /// exit point: cancellation is cooperative, so a released-then-re-pressed sequence (stop() then a
    /// new begin()) can leave a stale attempt resuming from a completed await — it must NOT wipe the
    /// new attempt's startTask (which would strand a hot mic no stop() could cancel), commit .talking,
    /// or tear down the new attempt's peer connection. The generation makes "am I still current?"
    /// answerable at each of connect()'s several exit points.
    private var connectGeneration = 0

    override init() {
        super.init()
        // Stop talking + free the mic/connection if the app backgrounds (don't hold the
        // recording session open behind the user's back).
        bgObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    deinit {
        if let bgObserver { NotificationCenter.default.removeObserver(bgObserver) }
    }

    var isActive: Bool { status == .connecting || status == .talking }

    /// Begin talking to `camera` (mic-button press). Synchronous entry point that OWNS the
    /// connect Task, so a quick release — `stop()` — can cancel an in-flight handshake. Without
    /// this, a press released before the SDP exchange completed would open the mic + peer
    /// connection *after* the finger lifted, with no release event left to close it.
    func begin(cameraTwoWaySource: String, client: FrigateClient) {
        guard !isActive, startTask == nil else { return }
        status = .connecting
        connectGeneration &+= 1
        let generation = connectGeneration
        startTask = Task { [weak self] in
            await self?.connect(cameraTwoWaySource: cameraTwoWaySource, client: client, generation: generation)
            // Only clear the handle if a newer begin()/stop() hasn't superseded this attempt —
            // otherwise a stale attempt finishing here would wipe the current attempt's startTask,
            // and the next stop() couldn't cancel it (stuck hot mic).
            guard let self, self.connectGeneration == generation else { return }
            self.startTask = nil
        }
    }

    /// Resolves mic permission, builds the peer connection, gathers ICE, exchanges SDP with
    /// go2rtc, and opens the audio. Checks for cancellation at every await so a released press
    /// tears down cleanly and never strands an open mic.
    private func connect(cameraTwoWaySource: String, client: FrigateClient, generation: Int) async {
        guard await requestMicPermission() else {
            if !Task.isCancelled, connectGeneration == generation { status = .failed("Microphone access denied") }
            return
        }
        guard !Task.isCancelled, connectGeneration == generation else { return }   // nothing acquired yet — just bail
        configureAudioSession()

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        // STUN for the direct LAN path + TURN (minted by the relay) so talk also works away from
        // home, where the Cloudflare tunnel proxies only HTTPS/WS and ICE has no media path.
        config.iceServers = await TurnSettings.iceServers()
        config.bundlePolicy = .maxBundle
        config.iceTransportPolicy = .all     // direct on LAN, relay (TURN) when needed
        guard !Task.isCancelled, connectGeneration == generation else { teardown(generation: generation); return }   // audio session is live — clean it up
        startConnectWatchdog()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            if connectGeneration == generation { status = .failed("Couldn't create connection") }
            teardown(generation: generation)
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
            try Task.checkCancellation()
            try await setLocal(offer, on: pc)
            await waitForIceGathering(pc)   // non-trickle: send the offer with candidates baked in
            try Task.checkCancellation()

            let localSDP = pc.localDescription?.sdp ?? offer.sdp
            let answerSDP = try await client.webRTCAnswer(source: cameraTwoWaySource, offerSDP: localSDP)
            try Task.checkCancellation()
            try await setRemote(RTCSessionDescription(type: .answer, sdp: answerSDP), on: pc)
            try Task.checkCancellation()   // last gate before we commit to "talking"
            // A newer begin()/stop() superseded us during the handshake — it owns the connection
            // now, so don't commit .talking or touch shared state (the superseding stop() already
            // tore this attempt's resources down).
            guard connectGeneration == generation else { return }
            connectWatchdog?.cancel(); connectWatchdog = nil
            status = .talking
            Haptics.success()
        } catch {
            // Superseded by a newer attempt: leave its state and connection alone.
            guard connectGeneration == generation else { return }
            // Released mid-handshake: silently tear down and leave status as stop() set it (.idle).
            if error.isCancellation || Task.isCancelled {
                teardown(generation: generation)
            } else {
                status = .failed(error.localizedDescription)
                teardown(generation: generation)
            }
        }
    }

    func stop() {
        connectGeneration &+= 1   // supersede any in-flight connect so it can't commit or tear down shared state
        startTask?.cancel()
        startTask = nil
        teardown()
        status = .idle
    }

    // MARK: - Internals

    /// Release the mic + peer connection + audio session. Callers inside connect() pass their
    /// `generation` so a superseded attempt no-ops instead of closing the *current* attempt's pc
    /// (the stop() that superseded it already released the old one). stop()/the watchdog/the ICE-drop
    /// delegate pass nothing, so their teardown always runs.
    private func teardown(generation: Int? = nil) {
        if let generation, generation != connectGeneration { return }
        connectWatchdog?.cancel(); connectWatchdog = nil
        micTrack = nil
        pc?.delegate = nil       // stop delegate callbacks from firing after close
        pc?.close()
        pc = nil
        gatheringContinuation?.resume()
        gatheringContinuation = nil
        deactivateAudioSession()
    }

    /// 6s budget from `.connecting`: a remote attempt with no reachable media path fails here
    /// with actionable copy instead of spinning. Cancelled on success and in teardown.
    private func startConnectWatchdog() {
        connectWatchdog?.cancel()
        connectWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled, self.status == .connecting else { return }
            self.status = .failed(TurnSettings.hasRelay
                ? "Couldn't reach the camera's audio. Check the camera is online and that TURN is set on the relay."
                : "Two-way talk needs the relay's TURN key to work away from home (set it in the relay's admin settings).")
            // Cancel the in-flight connect so, when its pending await returns, it bails at the next
            // cancellation checkpoint instead of resuming on the now-torn-down peer connection.
            self.startTask?.cancel()
            self.teardown()
        }
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
            // If the timeout won, the gather-wait child is still suspended on its
            // continuation — resume it so the group can finish (else this hangs forever).
            gatheringContinuation?.resume()
            gatheringContinuation = nil
            group.cancelAll()
        }
    }

    enum TalkError: Error { case noOffer }
}

// MARK: - RTCPeerConnectionDelegate (required stubs; we only act on gathering + ICE state)

extension TwoWayTalkController: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        guard newState == .complete else { return }
        Task { @MainActor [weak self] in
            self?.gatheringContinuation?.resume()
            self?.gatheringContinuation = nil
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        // Only treat a hard drop as failure — `.disconnected` is often transient (a brief network
        // blip that ICE recovers from on its own), so don't tear down the talk session on it.
        if newState == .failed || newState == .closed {
            Task { @MainActor [weak self] in
                guard let self, self.status == .talking else { return }
                self.status = .failed("Connection lost")
                // Free the mic + `.playAndRecord` session immediately — don't leave a hot mic and
                // ducked audio live until the user happens to lift the press-hold button.
                // teardown() is idempotent, so the release-driven stop() is still safe.
                self.teardown()
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
