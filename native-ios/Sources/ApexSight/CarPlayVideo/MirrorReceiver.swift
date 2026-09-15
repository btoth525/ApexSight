import CoreMedia
import Foundation
import Network
import ReplayKit
import Transcoding
import UIKit

/// The app side of phone-screen mirroring. The ReplayKit broadcast extension (`ApexMirror`)
/// encodes the screen to H.264 Annex-B and streams it over loopback TCP; this listens on
/// 127.0.0.1:12345, decodes with VideoToolbox, and hands decoded frames to `CarVideoSession`.
///
/// Protocol: extension → app = raw Annex-B bytes. App → extension = ASCII commands:
/// `KEYFRAME` (re-send SPS/PPS + an IDR; sent on connect and whenever decoding stalls) and
/// `STOP` (end the broadcast — picking a feed while mirroring drops the red status bar).
@MainActor
final class MirrorReceiver {
    static let shared = MirrorReceiver()
    static let port: NWEndpoint.Port = 12345

    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onFailure: ((String) -> Void)?

    private var listener: NWListener?
    private var connection: NWConnection?
    private var decoder: VideoDecoderAnnexBAdaptor?
    private var decodePump: Task<Void, Never>?
    private var stallWatchdog: Task<Void, Never>?
    private var bytesSinceFrame = 0
    private var lastKeyframeRequest: TimeInterval = 0
    private let networkQueue = DispatchQueue(label: "com.brandontoth.apexsight.mirror", qos: .userInteractive)

    private init() {}

    func start() {
        stop()
        let videoDecoder = VideoDecoder(config: .init(realTime: true))
        let decoder = VideoDecoderAnnexBAdaptor(videoDecoder: videoDecoder, codec: .h264)
        self.decoder = decoder
        decodePump = Task { [weak self] in
            for await buffer in videoDecoder.decodedSampleBuffers {
                guard let self, !Task.isCancelled else { return }
                bytesSinceFrame = 0
                onSampleBuffer?(buffer)
            }
        }
        do {
            let listener = try NWListener(using: .tcp, on: Self.port)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    Task { @MainActor [weak self] in self?.onFailure?("Mirror listener failed: \(error.localizedDescription)") }
                }
            }
            listener.start(queue: networkQueue)
            self.listener = listener
        } catch {
            onFailure?("Couldn't open the mirror port: \(error.localizedDescription)")
            return
        }
        presentBroadcastPicker()
    }

    func stop() {
        send("STOP")
        connection?.cancel(); connection = nil
        listener?.cancel(); listener = nil
        decodePump?.cancel(); decodePump = nil
        stallWatchdog?.cancel(); stallWatchdog = nil
        decoder = nil
        bytesSinceFrame = 0
    }

    // MARK: - Connection

    private func accept(_ incoming: NWConnection) {
        connection?.cancel()
        connection = incoming
        incoming.start(queue: networkQueue)
        receive(on: incoming)
        requestKeyframe(force: true)
        // A stream that is arriving but not decoding (joined mid-GOP, corrupt SPS) needs a fresh
        // keyframe; ask at most every 2 s.
        stallWatchdog?.cancel()
        stallWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if bytesSinceFrame > 256 * 1024 { requestKeyframe(force: false) }
            }
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else { return }
                if let data, !data.isEmpty {
                    bytesSinceFrame += data.count
                    decoder?.decode(data)
                }
                if isComplete || error != nil {
                    onFailure?("Mirror ended")
                    return
                }
                receive(on: connection)
            }
        }
    }

    private func requestKeyframe(force: Bool) {
        let now = Date().timeIntervalSinceReferenceDate
        guard force || now - lastKeyframeRequest > 2 else { return }
        lastKeyframeRequest = now
        send("KEYFRAME")
    }

    private func send(_ command: String) {
        guard let connection, let data = command.data(using: .utf8) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - Broadcast picker

    /// iOS only lets a broadcast start from the system picker, on the PHONE — the driver /
    /// passenger taps "Start Broadcast" once; iOS remembers the extension afterwards.
    private func presentBroadcastPicker() {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.keyWindow?.rootViewController ?? scene.windows.first?.rootViewController else {
            onFailure?("Open ApexSight on your iPhone to start mirroring")
            return
        }
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        picker.preferredExtension = (Bundle.main.bundleIdentifier ?? "") + ".ApexMirror"
        picker.showsMicrophoneButton = false
        picker.alpha = 0.02
        root.view.addSubview(picker)
        // The picker only opens from its own button — tap it programmatically.
        (picker.subviews.compactMap { $0 as? UIButton }.first)?.sendActions(for: .touchUpInside)
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            picker.removeFromSuperview()
        }
    }
}
