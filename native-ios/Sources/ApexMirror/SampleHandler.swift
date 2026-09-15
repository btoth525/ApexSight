import Network
import ReplayKit
import Transcoding

/// Broadcast Upload Extension: encodes the iPhone screen to H.264 Annex-B with VideoToolbox and
/// streams it to the app over loopback TCP (the app is the server; this is the client and keeps
/// retrying until the app is listening). The extension is capped at ~50 MB, so frames are encoded
/// the moment they arrive and nothing is queued.
final class SampleHandler: RPBroadcastSampleHandler {
    private var connection: NWConnection?
    private let videoEncoder: VideoEncoder
    private let encoder: VideoEncoderAnnexBAdaptor
    private var pump: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var isFinishing = false
    private let queue = DispatchQueue(label: "com.brandontoth.apexsight.mirror.ext", qos: .userInteractive)

    override init() {
        var config = VideoEncoder.Config.ultraLowLatency
        config.averageBitRate = 6_000_000
        config.expectedFrameRate = 30
        config.maxKeyFrameInterval = 60
        let videoEncoder = VideoEncoder(config: config)
        self.videoEncoder = videoEncoder
        encoder = VideoEncoderAnnexBAdaptor(videoEncoder: videoEncoder)
        super.init()
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        isFinishing = false
        pump = Task { [encoder, weak self] in
            for await data in encoder.annexBData {
                guard let self else { return }
                self.connection?.send(content: data, completion: .contentProcessed { _ in })
            }
        }
        connect()
    }

    override func broadcastFinished() {
        isFinishing = true
        pump?.cancel(); pump = nil
        reconnect?.cancel(); reconnect = nil
        connection?.cancel(); connection = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, connection?.state == .ready else { return }
        videoEncoder.encode(sampleBuffer)
    }

    // MARK: - Connection

    private func connect() {
        guard !isFinishing else { return }
        // A fresh compression session on every (re)connect → SPS/PPS + IDR first.
        videoEncoder.invalidate()
        let connection = NWConnection(host: "127.0.0.1", port: 12345, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                listenForCommands(on: connection)
            case .failed, .waiting, .cancelled:
                guard self.connection === connection, !isFinishing else { return }
                connection.cancel()
                self.connection = nil
                reconnect?.cancel()
                reconnect = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.connect()
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func listenForCommands(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { [weak self] data, _, isComplete, _ in
            guard let self, self.connection === connection else { return }
            if let data, let text = String(data: data, encoding: .utf8) {
                if text.contains("KEYFRAME") { videoEncoder.invalidate() }
                if text.contains("STOP") {
                    finishBroadcastWithError(NSError(domain: "com.brandontoth.apexsight.mirror", code: 1,
                                                     userInfo: [NSLocalizedDescriptionKey: "Mirroring stopped from ApexSight"]))
                    return
                }
            }
            if !isComplete { listenForCommands(on: connection) }
        }
    }
}
