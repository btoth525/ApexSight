import CallKit
import PushKit
import AVFoundation
import UIKit

extension Notification.Name {
    /// Posted when the user answers the doorbell from the native CallKit screen — MainTabView
    /// presents the DoorbellCallView (already answered) in response.
    static let apexDoorbellAnswered = Notification.Name("apex.doorbell.answered")
    /// Posted when the call ends (declined / ended from CallKit) so a presented call UI dismisses.
    static let apexDoorbellEnded = Notification.Name("apex.doorbell.ended")
}

/// Turns a doorbell ring into a real iOS phone call: a VoIP (PushKit) push from the relay reports a
/// CallKit incoming call, so the native full-screen call UI rings even on the Lock Screen. Answering
/// foregrounds the app into the live doorbell view + two-way talk; declining/ending clears the call.
final class DoorbellCallManager: NSObject {
    static let shared = DoorbellCallManager()

    private let provider: CXProvider
    private let callController = CXCallController()
    private var voipRegistry: PKPushRegistry?
    private var currentCallID: UUID?
    /// True once the current call was answered — the ring timeout must never end a live call.
    private var callAnswered = false
    /// When the current call was reported. A doorbell "call" has no remote party to hang up, so
    /// nothing ends it except an explicit End tap — answer one and walk away (lock the phone, put
    /// it down) and it stays live FOREVER. `currentCallID` then never clears, every later ring is
    /// treated as a duplicate and silently killed, and the doorbell stops ringing that phone until
    /// the app is relaunched. This timestamp is what lets a stale call be recognised and cleared.
    private var callStartedAt: Date?
    /// Backstop that ends an ANSWERED call so it cannot wedge the ring path forever.
    private var answeredTimeoutTask: Task<Void, Never>?
    /// Longest a doorbell call may live. Well past any real doorstep conversation, and far short of
    /// "until the app restarts" — which is how long the wedge used to last.
    private static let maxCallLifetime: TimeInterval = 300
    /// Ends an unanswered ring after a grace period. Without this a missed ring left
    /// `currentCallID` set forever, so every LATER ring was treated as a "duplicate" and dropped —
    /// and dropping a VoIP push without reporting a call gets the app BLACKLISTED from VoIP pushes
    /// by iOS entirely (the "doorbell stopped ringing my phone" failure).
    private var ringTimeoutTask: Task<Void, Never>?
    /// Set when the user answers from CallKit before the SwiftUI scene exists (cold launch from a
    /// VoIP push on the Lock Screen) — NotificationCenter posts aren't buffered, so MainTabView
    /// consumes this on appear to replay the answer into the call UI.
    private(set) var pendingAnswer = false

    /// One-shot: MainTabView calls this on appear to catch an answer that happened pre-UI.
    func consumePendingAnswer() -> Bool {
        let had = pendingAnswer
        pendingAnswer = false
        return had
    }

    private override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        // Doorbell rings are not phone calls — keep them out of the Phone app's Recents list
        // (what Ring/Nest do; otherwise every visitor press clutters call history).
        config.includesCallsInRecents = false
        // Ringtone-style incoming call; the ApexSight icon shows on the CallKit screen.
        if let icon = UIImage(named: "AppIcon")?.pngData() { config.iconTemplateImageData = icon }
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    /// Register for VoIP pushes. Called once at launch so the app can be woken to ring even when
    /// fully closed. The token is registered to the relay so it can target this phone.
    func start() {
        guard voipRegistry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        voipRegistry = registry
    }

    /// Report an incoming doorbell call to CallKit.
    ///
    /// ABSOLUTE RULE (iOS 13+): EVERY VoIP push must be reported via `reportNewIncomingCall` before
    /// the push handler completes — no early returns, no guards. Swallowing even one push makes iOS
    /// terminate the app, and repeated violations get the app SILENTLY BLACKLISTED from all VoIP
    /// pushes until it's deleted and reinstalled (the "doorbell just stopped ringing" bug). A
    /// duplicate press while already ringing is still REPORTED, then immediately cleared — that
    /// satisfies the rule without disturbing the live call (different UUID).
    private func reportIncomingDoorbell(completion: @escaping () -> Void) {
        let id = UUID()
        // Before anything else: if the "live" call is older than any real doorstep conversation, it
        // is a wedge, not a call. Clear it so THIS ring is treated as fresh and actually rings.
        // Without this, one answered-and-abandoned call silences the doorbell indefinitely.
        if let stale = currentCallID,
           let since = callStartedAt,
           Date().timeIntervalSince(since) > Self.maxCallLifetime {
            diag("clearing stale call (\(Int(Date().timeIntervalSince(since)))s old) before reporting new ring")
            provider.reportCall(with: stale, endedAt: nil, reason: .failed)
            currentCallID = nil
            callStartedAt = nil
            callAnswered = false
            ringTimeoutTask?.cancel()
            answeredTimeoutTask?.cancel()
        }
        let duplicate = currentCallID != nil
        if !duplicate {
            currentCallID = id
            callStartedAt = Date()
            callAnswered = false
        }
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "Front Doorbell")
        update.localizedCallerName = "Front Doorbell"
        update.hasVideo = true
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        provider.reportNewIncomingCall(with: id, update: update) { [weak self] error in
            guard let self else { completion(); return }
            if duplicate {
                // Rule satisfied (we reported); now clear the extra call so only the original
                // keeps ringing. Its UUID differs from the live call's, so this can't end it.
                self.diag("ring suppressed as duplicate — a call is already live")
                self.provider.reportCall(with: id, endedAt: nil, reason: .answeredElsewhere)
            } else if let error {
                // A failed report must not leave a dead ID behind (it would block future rings).
                self.diag("reportNewIncomingCall FAILED: \(error.localizedDescription)", level: .error)
                self.currentCallID = nil
                self.callStartedAt = nil
            } else {
                self.diag("CallKit ringing")
                self.scheduleRingTimeout(for: id)
            }
            completion()
        }
    }

    /// End an unanswered ring after 45s so a missed call can never wedge `currentCallID` (which
    /// would drop every future ring). Cancelled on answer/end; never touches an answered call.
    /// The check+end hops to the MAIN actor: every PushKit/CXProvider callback in this class runs
    /// on the main queue (PKPushRegistry(queue: .main), setDelegate(queue: nil)), so state reads
    /// off-main would race an answer landing at the ~45s mark — the timeout could tear down a
    /// just-answered live call as "unanswered".
    private func scheduleRingTimeout(for id: UUID) {
        ringTimeoutTask?.cancel()
        ringTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard self.currentCallID == id, !self.callAnswered else { return }
                self.provider.reportCall(with: id, endedAt: nil, reason: .unanswered)
                self.currentCallID = nil
                self.callStartedAt = nil
            }
        }
    }

    /// End an ANSWERED call once it has outlived any plausible doorstep conversation.
    ///
    /// The ring timeout deliberately never touches an answered call — but a doorbell call has no
    /// remote party, so answering one and simply walking away left it live forever. That kept
    /// `currentCallID` set, which made every subsequent ring look like a duplicate and got it
    /// killed on arrival: the doorbell went silent on that phone with nothing in any log to say so.
    /// This is the backstop that makes that state impossible rather than merely unlikely.
    private func scheduleAnsweredTimeout(for id: UUID) {
        answeredTimeoutTask?.cancel()
        answeredTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.maxCallLifetime * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard self.currentCallID == id else { return }
                self.diag("auto-ending answered call after \(Int(Self.maxCallLifetime))s so it can't wedge future rings")
                self.provider.reportCall(with: id, endedAt: nil, reason: .remoteEnded)
                self.currentCallID = nil
                self.callStartedAt = nil
                self.callAnswered = false
                NotificationCenter.default.post(name: .apexDoorbellEnded, object: nil)
            }
        }
    }

    /// Record a doorbell-call event in the app's own log so the next "my phone didn't ring" is
    /// answerable from `/v1/diag` instead of by inference. Hops to the main actor rather than
    /// assuming it: this is called from PushKit and CXProvider callbacks.
    private func diag(_ message: String, level: DiagnosticLog.Level = .info) {
        Task { @MainActor in
            switch level {
            case .error:   DiagnosticLog.shared.error("doorbell-call", message)
            case .warning: DiagnosticLog.shared.warning("doorbell-call", message)
            case .info:    DiagnosticLog.shared.info("doorbell-call", message)
            }
        }
    }

    /// Answer the current CallKit call from the app side (the in-app Answer button) so the native
    /// call UI reflects the answered state instead of ringing on over the live view.
    func answerCurrentCall() {
        guard let id = currentCallID else { return }
        callController.request(CXTransaction(action: CXAnswerCallAction(call: id))) { _ in }
    }

    /// End the current call from the app side (the in-app Decline/End button) so the CallKit call
    /// clears too.
    func endCurrentCall() {
        guard let id = currentCallID else { return }
        let end = CXEndCallAction(call: id)
        callController.request(CXTransaction(action: end)) { _ in }
        // Also tell CallKit directly so the UI clears even if the transaction races.
        provider.reportCall(with: id, endedAt: nil, reason: .remoteEnded)
        currentCallID = nil
        callStartedAt = nil
        callAnswered = false
        ringTimeoutTask?.cancel()
        answeredTimeoutTask?.cancel()
    }
}

// MARK: - PushKit

extension DoorbellCallManager: PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let hex = credentials.token.map { String(format: "%02x", $0) }.joined()
        DeviceTokenStore.voipToken = hex
        registerVoIPWithRelay(hex)
    }

    /// Re-send the cached VoIP token to the relay. iOS delivers a token via `didUpdate` only when it
    /// changes (often just once per install), so a registration that failed at launch — or a relay
    /// whose device table was reset (admin "Reset data" forces clients to re-identify) — would
    /// otherwise leave this phone unable to ring until a reinstall. Call on every foreground so the
    /// doorbell registration self-heals.
    func reregisterVoIP() {
        guard let hex = DeviceTokenStore.voipToken, !hex.isEmpty else { return }
        registerVoIPWithRelay(hex)
    }

    private func registerVoIPWithRelay(_ hex: String) {
        Task {
            let relayURL = DeviceTokenStore.relayURL
            let pairing = DeviceTokenStore.ensurePairingCode()
            guard !relayURL.isEmpty, !pairing.isEmpty else { return }
            try? await RelayClient.registerVoIP(relayURL: relayURL, voipToken: hex, pairingCode: pairing,
                                                environment: APNSEnvironment.current,
                                                deviceName: DeviceTokenStore.deviceName)
        }
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        if type == .voIP { DeviceTokenStore.voipToken = nil }
    }

    func pushRegistry(_ registry: PKPushRegistry,
                      didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType,
                      completion: @escaping () -> Void) {
        guard type == .voIP else { completion(); return }
        // First line of the black box: this proves the push REACHED the phone. Its absence after a
        // relay that logged a successful send is the difference between "APNs never delivered it"
        // and "we delivered it and the app dropped it" — which used to take a forensic session.
        diag("VoIP push received")
        // Report to CallKit immediately — required, or the app is killed for swallowing a VoIP push.
        reportIncomingDoorbell(completion: completion)
        // Kick the on-demand doorbell encoder awake now, while the phone rings — so the live video
        // is already flowing by the time you answer instead of spinning up cold on tap.
        DoorbellPrewarmer.warm()
    }
}

// MARK: - CallKit

extension DoorbellCallManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        currentCallID = nil
        callStartedAt = nil
        callAnswered = false
        ringTimeoutTask?.cancel()
        answeredTimeoutTask?.cancel()
        // Clear the cold-launch answer flag too — a stale one would make MainTabView replay a
        // phantom "answered" into a full-screen call UI for a call that no longer exists.
        pendingAnswer = false
        NotificationCenter.default.post(name: .apexDoorbellEnded, object: nil)
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // Foreground the app into the live doorbell view. Also record the answer: on a cold launch
        // (app terminated, answered from the Lock Screen) this fires before any SwiftUI scene is
        // observing, and NotificationCenter posts aren't buffered — MainTabView consumes the flag
        // on appear and replays the answer.
        callAnswered = true
        ringTimeoutTask?.cancel()
        // An answered call still needs an end, or it wedges the ring path — see the doc comment.
        if let id = currentCallID { scheduleAnsweredTimeout(for: id) }
        pendingAnswer = true
        diag("call answered")
        NotificationCenter.default.post(name: .apexDoorbellAnswered, object: nil)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        currentCallID = nil
        callStartedAt = nil
        callAnswered = false
        ringTimeoutTask?.cancel()
        answeredTimeoutTask?.cancel()
        pendingAnswer = false
        NotificationCenter.default.post(name: .apexDoorbellEnded, object: nil)
        action.fulfill()
    }

    /// CallKit owns the audio session for the call; the two-way-talk controller starts its WebRTC
    /// audio once the session is active.
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {}
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}
}
