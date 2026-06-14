import Foundation
import CallKit
import PushKit
import AVFoundation

// MARK: - Active Call model (drives fullScreenCover in ContentView)

struct ActiveCall: Identifiable {
    let id = UUID()
    let uuid: UUID
    let cameraName: String
    let callerName: String
}

// MARK: - DoorbellManager

@MainActor
final class DoorbellManager: NSObject, ObservableObject {
    static let shared = DoorbellManager()
    private override init() {}

    @Published var activeCall: ActiveCall?
    @Published var voipToken: String?

    // Maps call UUID → camera name so we know which stream to open on answer
    private var cameraByUUID: [String: String] = [:]

    private var provider: CXProvider?
    private let callController = CXCallController()
    private var registry: PKPushRegistry?

    // MARK: - Setup

    func registerForVoIPPushes() {
        let config = CXProviderConfiguration()
        config.localizedName = "Apex"
        config.supportsVideo = true
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.iconTemplateImageData = UIImage(systemName: "video.fill")?.pngData()

        provider = CXProvider(configuration: config)
        provider?.setDelegate(self, queue: .main)

        registry = PKPushRegistry(queue: .main)
        registry?.delegate = self
        registry?.desiredPushTypes = [.voIP]

        // Restore stored token if available
        if let stored = KeychainHelper.read(service: "ApexSight", account: "voip_push_token") {
            voipToken = stored
        }
    }

    // MARK: - End call (called by DoorbellCallView red button)

    func endCall(uuid: UUID) {
        let action = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: action)
        callController.request(transaction) { _ in }
        cameraByUUID.removeValue(forKey: uuid.uuidString)
        if activeCall?.uuid == uuid {
            activeCall = nil
        }
    }
}

// MARK: - PKPushRegistryDelegate

extension DoorbellManager: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry,
                                   didUpdate credentials: PKPushCredentials,
                                   for type: PKPushType) {
        guard type == .voIP else { return }
        let token = credentials.token.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in
            self.voipToken = token
            KeychainHelper.save(token, service: "ApexSight", account: "voip_push_token")
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry,
                                   didReceiveIncomingPushWith payload: PKPushPayload,
                                   for type: PKPushType,
                                   completion: @escaping () -> Void) {
        guard type == .voIP else { completion(); return }

        let dict = payload.dictionaryPayload
        let camera = dict["camera"] as? String ?? "doorbell_twoway"
        let caller = dict["caller"] as? String ?? "Front Door"
        let uuid = UUID()

        // Must call reportNewIncomingCall synchronously or iOS kills the app
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: caller)
        update.hasVideo = true
        update.localizedCallerName = caller
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsHolding = false

        Task { @MainActor in
            self.cameraByUUID[uuid.uuidString] = camera
        }

        self.provider?.reportNewIncomingCall(with: uuid, update: update) { error in
            completion()
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry,
                                   didInvalidatePushTokenFor type: PKPushType) {}
}

// MARK: - CXProviderDelegate

extension DoorbellManager: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {}

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        let uuid = action.callUUID
        Task { @MainActor in
            let camera = self.cameraByUUID[uuid.uuidString] ?? "doorbell_twoway"
            self.activeCall = ActiveCall(uuid: uuid, cameraName: camera, callerName: "Front Door")
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let uuid = action.callUUID
        Task { @MainActor in
            self.cameraByUUID.removeValue(forKey: uuid.uuidString)
            if self.activeCall?.uuid == uuid {
                self.activeCall = nil
            }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider,
                               didActivate audioSession: AVAudioSession) {
        try? audioSession.setCategory(.playAndRecord, mode: .voiceChat,
                                       options: [.allowBluetooth, .defaultToSpeaker])
        try? audioSession.setActive(true)
    }

    nonisolated func provider(_ provider: CXProvider,
                               didDeactivate audioSession: AVAudioSession) {
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }
}
