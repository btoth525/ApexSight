import AVFoundation
import CoreImage
import Transcoding
import UIKit

/// The one source of truth for "what video is playing for the car". Owns the active source — a
/// feed or the phone-screen mirror — and fans frames out to every attached `VideoCanvasView`
/// (the phone player, its PiP, the CarPlay window). Also produces a ~1 fps `UIImage` stream for
/// the CarPlay TEMPLATE path (driving-task entitlement), where the car can only show pictures.
@MainActor
final class CarVideoSession: ObservableObject {
    static let shared = CarVideoSession()

    enum Source: Equatable { case none, feed(Feed), mirror }
    enum State: Equatable { case idle, connecting, streaming, failed(String) }

    @Published private(set) var source: Source = .none
    @Published private(set) var state: State = .idle
    var isStreaming: Bool { state == .streaming }
    /// Something is drawing the video (phone player / PiP / CarPlay window).
    var hasViewers: Bool { canvases.count > 0 }

    // Feeds
    private let raw = CameraStreamClient()
    private var player: AVPlayer?
    private var playerStatusObs: NSKeyValueObservation?
    private var playerFailObs: NSObjectProtocol?
    private var h264Decoder: VideoDecoderAnnexBAdaptor?
    private var h264Pump: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var canvases = NSHashTable<VideoCanvasView>.weakObjects()

    // ~1 fps still frames for CarPlay templates. Set by the CarPlay delegate while a detail
    // screen is up; nil otherwise so no pixels are copied for nobody.
    var frameSampler: ((UIImage) -> Void)? {
        didSet { if frameSampler == nil { playerSamplerTask?.cancel(); playerSamplerTask = nil } else { startPlayerSamplerIfNeeded() } }
    }
    private var lastSampleAt: TimeInterval = 0
    private var videoOutput: AVPlayerItemVideoOutput?
    private var playerSamplerTask: Task<Void, Never>?
    // CIContext is thread-safe; the sampler renders on a detached task.
    nonisolated private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    private init() { raw.delegate = self }

    // MARK: - Canvases

    func attach(_ canvas: VideoCanvasView) {
        canvases.add(canvas)
        if let player { canvas.attachPlayer(player) }
    }

    func detach(_ canvas: VideoCanvasView) {
        canvases.remove(canvas)
        canvas.detachPlayer()
    }

    // MARK: - Feeds

    func play(_ feed: Feed) {
        stopInternal()
        source = .feed(feed)
        FeedStore.shared.lastSelectedID = feed.id
        if let message = Feed.unsupportedSchemeMessage(for: feed.url) {
            state = .failed(message)
            return
        }
        state = .connecting
        switch feed.kind {
        case .hls, .mp4:
            let item = AVPlayerItem(url: feed.url)
            item.preferredForwardBufferDuration = 2
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = false
            player.isMuted = true
            self.player = player
            playerStatusObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let status = player.timeControlStatus
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch status {
                    case .playing: state = .streaming
                    case .waitingToPlayAtSpecifiedRate: if state != .streaming { state = .connecting }
                    default: break
                    }
                }
            }
            playerFailObs = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.state = .failed("Playback failed")
                    self?.scheduleReconnect()
                }
            }
            canvases.allObjects.forEach { $0.attachPlayer(player) }
            startPlayerSamplerIfNeeded()
            player.play()
        case .mjpeg:
            raw.start(request: request(for: feed), codec: .mjpeg)
        case .h264:
            let videoDecoder = VideoDecoder(config: .init(realTime: true))
            let decoder = VideoDecoderAnnexBAdaptor(videoDecoder: videoDecoder, codec: .h264)
            h264Decoder = decoder
            h264Pump = Task { [weak self] in
                for await buffer in videoDecoder.decodedSampleBuffers {
                    guard let self, !Task.isCancelled else { return }
                    deliver(decoded: buffer)
                }
            }
            raw.start(request: request(for: feed), codec: .h264)
        }
    }

    private func request(for feed: Feed) -> URLRequest {
        if feed.usesFrigateAuth, let session = KeychainStore().loadSession() {
            return FrigateClient(session: session).authedRequest(for: feed.url)
        }
        return URLRequest(url: feed.url)
    }

    func playLast() {
        if let feed = FeedStore.shared.resumeFeed { play(feed) } else { state = .idle }
    }

    func stop() {
        stopInternal()
        source = .none
        state = .idle
    }

    func restart() {
        switch source {
        case .feed(let feed): play(feed)
        case .mirror: startMirror()
        case .none: playLast()
        }
    }

    private func stopInternal() {
        raw.stop()
        MirrorReceiver.shared.stop()
        reconnectTask?.cancel(); reconnectTask = nil
        h264Pump?.cancel(); h264Pump = nil
        h264Decoder = nil
        playerSamplerTask?.cancel(); playerSamplerTask = nil
        playerStatusObs?.invalidate(); playerStatusObs = nil
        if let playerFailObs { NotificationCenter.default.removeObserver(playerFailObs) }
        playerFailObs = nil
        if let output = videoOutput { player?.currentItem?.remove(output) }
        videoOutput = nil
        player?.pause()
        player = nil
        canvases.allObjects.forEach { $0.detachPlayer(); $0.clear() }
    }

    private func scheduleReconnect() {
        guard case .feed = source, canvases.count > 0 || frameSampler != nil else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.restart()
        }
    }

    // MARK: - Mirror

    func startMirror() {
        stopInternal()
        source = .mirror
        state = .connecting
        MirrorReceiver.shared.onSampleBuffer = { [weak self] buffer in
            Task { @MainActor [weak self] in self?.deliver(decoded: buffer) }
        }
        MirrorReceiver.shared.onFailure = { [weak self] message in
            Task { @MainActor [weak self] in self?.state = .failed(message) }
        }
        MirrorReceiver.shared.start()
    }

    // MARK: - Frame delivery

    private func deliver(decoded buffer: CMSampleBuffer) {
        if state != .streaming { state = .streaming }
        canvases.allObjects.forEach { $0.display(sampleBuffer: buffer) }
        sample(pixelBuffer: CMSampleBufferGetImageBuffer(buffer))
    }

    private func deliver(jpeg: Data) {
        if state != .streaming { state = .streaming }
        canvases.allObjects.forEach { $0.display(jpeg: jpeg) }
        guard let sampler = frameSampler, throttleSample() else { return }
        Task.detached(priority: .utility) {
            guard let image = RemoteImage.downsample(jpeg, maxPixel: 720) else { return }
            await MainActor.run { sampler(image) }
        }
    }

    private func sample(pixelBuffer: CVPixelBuffer?) {
        guard let sampler = frameSampler, let pixelBuffer, throttleSample() else { return }
        Task.detached(priority: .utility) {
            let ci = CIImage(cvPixelBuffer: pixelBuffer)
            let scale = min(1, 720 / max(ci.extent.width, ci.extent.height))
            let scaled = scale < 1 ? ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : ci
            guard let cg = Self.ciContext.createCGImage(scaled, from: scaled.extent) else { return }
            let image = UIImage(cgImage: cg)
            await MainActor.run { sampler(image) }
        }
    }

    private func throttleSample() -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastSampleAt >= 1 else { return false }
        lastSampleAt = now
        return true
    }

    /// HLS/MP4 pixels come out of `AVPlayerItemVideoOutput`, polled once a second while a sampler exists.
    private func startPlayerSamplerIfNeeded() {
        guard frameSampler != nil, let player, let item = player.currentItem, playerSamplerTask == nil else { return }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        videoOutput = output
        playerSamplerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled, let item = self.player?.currentItem else { return }
                let time = item.currentTime()
                if output.hasNewPixelBuffer(forItemTime: time),
                   let pixels = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                    sample(pixelBuffer: pixels)
                }
            }
        }
    }
}

extension CarVideoSession: CameraStreamClientDelegate {
    nonisolated func cameraStream(_ client: CameraStreamClient, jpeg: Data) {
        Task { @MainActor in self.deliver(jpeg: jpeg) }
    }

    nonisolated func cameraStream(_ client: CameraStreamClient, h264 annexB: Data) {
        // Decoded frames come back through `decodedSampleBuffers` (see play(_:)).
        Task { @MainActor in self.h264Decoder?.decode(annexB) }
    }

    nonisolated func cameraStream(_ client: CameraStreamClient, ended error: Error?) {
        let message = error?.localizedDescription ?? "Stream ended"
        Task { @MainActor in
            self.state = .failed(message)
            self.scheduleReconnect()
        }
    }
}
