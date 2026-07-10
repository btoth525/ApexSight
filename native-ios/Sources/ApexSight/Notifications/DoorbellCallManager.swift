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

    private override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
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

    /// Report an incoming doorbell call to CallKit (must happen synchronously in the push handler,
    /// or iOS terminates the app for not surfacing the VoIP push).
    private func reportIncomingDoorbell(completion: @escaping () -> Void) {
        let id = UUID()
        currentCallID = id
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "Front Doorbell")
        update.localizedCallerName = "Front Doorbell"
        update.hasVideo = true
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        provider.reportNewIncomingCall(with: id, update: update) { _ in completion() }
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
    }
}

// MARK: - PushKit

extension DoorbellCallManager: PKPushRegistryDelegate {
    func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let hex = credentials.token.map { String(format: "%02x", $0) }.joined()
        DeviceTokenStore.voipToken = hex
        Task {
            let relayURL = DeviceTokenStore.relayURL
            let pairing = DeviceTokenStore.ensurePairingCode()
            guard !relayURL.isEmpty, !pairing.isEmpty else { return }
            try? await RelayClient.registerVoIP(relayURL: relayURL, voipToken: hex, pairingCode: pairing,
                                                environment: APNSEnvironment.current)
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
        // Report to CallKit immediately — required, or the app is killed for swallowing a VoIP push.
        reportIncomingDoorbell(completion: completion)
    }
}

// MARK: - CallKit

extension DoorbellCallManager: CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        currentCallID = nil
        NotificationCenter.default.post(name: .apexDoorbellEnded, object: nil)
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // Foreground the app into the live doorbell view + two-way talk.
        NotificationCenter.default.post(name: .apexDoorbellAnswered, object: nil)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        currentCallID = nil
        NotificationCenter.default.post(name: .apexDoorbellEnded, object: nil)
        action.fulfill()
    }

    /// CallKit owns the audio session for the call; the two-way-talk controller starts its WebRTC
    /// audio once the session is active.
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {}
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}
}
