import AVKit
import AVFoundation
import SwiftUI
import UIKit

// MARK: - Stream rules

enum LiveStreamRules {
    /// Cameras whose MAIN stream is H.265/HEVC, which iOS AVPlayer often can't decode
    /// (black screen). These always fall back to the H.264 `_sub` stream.
    static func forcesSubStream(_ camera: String) -> Bool {
        camera.lowercased().contains("front_driveway")
    }
}

// MARK: - Live HLS model

/// Owns one tuned-for-live `AVPlayer`, watches it for stalls/failures, and rebuilds the
/// stream with exponential-backoff reconnect. On the first failure it tries a token
/// refresh (reusing stored credentials) before falling back to backoff retries, so an
/// expired `frigate_token` recovers transparently. After 3 consecutive failures on the
/// main stream it silently downgrades to the sub-stream (if one is provided), resetting
/// the retry counter so the sub gets its own full backoff budget.
@MainActor
final class HLSLiveModel: ObservableObject {
    enum State: Equatable {
        case connecting
        case playing
        case failed(String)
    }

    @Published private(set) var state: State = .connecting
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isMuted = true
    @Published private(set) var usingFallback = false

    private var makeURL: (() -> URL?)?
    private var makeSubURL: (() -> URL?)?
    private var makeItem: ((URL) -> AVPlayerItem?)?
    private var reauth: (() async -> Bool)?

    private var statusObs: NSKeyValueObservation?
    private var timeControlObs: NSKeyValueObservation?
    private var stallObs: NSObjectProtocol?
    private var failObs: NSObjectProtocol?
    private var reconnectTask: Task<Void, Never>?
    private var retryCount = 0
    private var didTryReauth = false
    private var isStopped = false

    func configure(
        makeURL: @escaping () -> URL?,
        makeSubURL: (() -> URL?)? = nil,
        makeItem: @escaping (URL) -> AVPlayerItem?,
        reauth: @escaping () async -> Bool
    ) {
        self.makeURL = makeURL
        self.makeSubURL = makeSubURL
        self.makeItem = makeItem
        self.reauth = reauth
    }

    func start() {
        isStopped = false
        retryCount = 0
        didTryReauth = false
        usingFallback = false
        connect()
    }

    func stop() {
        isStopped = true
        reconnectTask?.cancel()
        reconnectTask = nil
        teardownObservers()
        player?.pause()
        player = nil
    }

    func toggleMute() {
        isMuted.toggle()
        if !isMuted {
            // Only claim the audio session when the user actually wants sound.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        player?.isMuted = isMuted
    }

    func reload() {
        retryCount = 0
        didTryReauth = false
        connect()
    }

    private func connect() {
        let urlSource = (usingFallback ? makeSubURL : makeURL) ?? makeURL
        guard !isStopped, let makeItem, let url = urlSource?(), let item = makeItem(url) else { return }
        teardownObservers()
        player?.pause()

        // Live tuning: tiny forward buffer + don't wait to minimize stalling = low latency.
        item.preferredForwardBufferDuration = 2

        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.automaticallyWaitsToMinimizeStalling = false
        newPlayer.actionAtItemEnd = .none
        newPlayer.isMuted = isMuted
        player = newPlayer
        state = .connecting

        statusObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in self?.handleStatus(item) }
        }
        timeControlObs = newPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                if player.timeControlStatus == .playing {
                    self.state = .playing
                    self.retryCount = 0
                    self.didTryReauth = false
                }
            }
        }
        stallObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleReconnect(reason: "Reconnecting…") }
        }
        failObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "Playback failed"
            Task { @MainActor in self?.handleFailure(message) }
        }

        newPlayer.play()
    }

    private func handleStatus(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            player?.play()
        case .failed:
            handleFailure(item.error?.localizedDescription ?? "Stream error")
        default:
            break
        }
    }

    private func handleFailure(_ message: String) {
        guard !isStopped else { return }
        // First failure on this run → try one token refresh, then fall back to backoff.
        if !didTryReauth, let reauth {
            didTryReauth = true
            Task { @MainActor in
                if await reauth() {
                    connect()
                } else {
                    scheduleReconnect(reason: message)
                }
            }
        } else {
            scheduleReconnect(reason: message)
        }
    }

    private func scheduleReconnect(reason: String) {
        guard !isStopped, reconnectTask == nil else { return }
        retryCount += 1

        // After 3 failures on main stream, silently downgrade to sub-stream.
        if !usingFallback, retryCount >= 3, makeSubURL != nil {
            usingFallback = true
            retryCount = 0
            didTryReauth = false
            state = .connecting
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    guard let self else { return }
                    self.reconnectTask = nil
                    self.connect()
                }
            }
            return
        }

        guard retryCount <= 6 else {
            state = .failed(reason)
            return
        }
        state = .connecting
        let delay = min(pow(2.0, Double(retryCount - 1)), 16)   // 1,2,4,8,16,16s
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                guard let self else { return }
                self.reconnectTask = nil
                self.connect()
            }
        }
    }

    private func teardownObservers() {
        statusObs?.invalidate(); statusObs = nil
        timeControlObs?.invalidate(); timeControlObs = nil
        if let stallObs { NotificationCenter.default.removeObserver(stallObs) }
        stallObs = nil
        if let failObs { NotificationCenter.default.removeObserver(failObs) }
        failObs = nil
    }
}

// MARK: - Live HLS view

struct HLSLivePlayerView: View {
    @EnvironmentObject private var appState: AppState
    let camera: FrigateCamera
    /// H.265 cameras are always forced to sub by `LiveStreamRules` regardless of this flag.
    /// Set to `true` only when you explicitly want the sub-stream (never used by default now).
    var preferSub: Bool = false
    /// Show the mute/refresh overlay controls (fullscreen only).
    var showControls: Bool = false
    var onPlaying: ((Bool) -> Void)? = nil

    @StateObject private var model = HLSLiveModel()

    /// H.265 cameras must always use sub; otherwise start with main and fall back to sub.
    private var alwaysSub: Bool { LiveStreamRules.forcesSubStream(camera.name) || preferSub }

    var body: some View {
        ZStack {
            if let player = model.player {
                ZoomablePlayerView(player: player)
            }

            switch model.state {
            case .connecting:
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.3)
                    .allowsHitTesting(false)
            case .failed(let message):
                failureOverlay(message)
            case .playing:
                EmptyView()
            }

            if showControls {
                controls
            }
        }
        .onAppear {
            if alwaysSub {
                // Forced sub: only one URL, no fallback needed.
                model.configure(
                    makeURL: { appState.client?.liveHLSURL(camera: camera.name, sub: true) },
                    makeItem: { url in appState.client?.playerItem(for: url) },
                    reauth: { await appState.reauthenticate() }
                )
            } else {
                // Start on main stream; fall back to sub after 3 consecutive failures.
                model.configure(
                    makeURL: { appState.client?.liveHLSURL(camera: camera.name, sub: false) },
                    makeSubURL: { appState.client?.liveHLSURL(camera: camera.name, sub: true) },
                    makeItem: { url in appState.client?.playerItem(for: url) },
                    reauth: { await appState.reauthenticate() }
                )
            }
            model.start()
        }
        .onDisappear { model.stop() }
        .onChange(of: model.state) { _, newState in
            onPlaying?(newState == .playing)
        }
    }

    private var controls: some View {
        HStack {
            Spacer()
            Button { model.toggleMute() } label: {
                Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 15, weight: .black))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .foregroundStyle(.white)
            }
            .padding(.trailing, 16)
        }
    }

    private func failureOverlay(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Button {
                model.reload()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.white, in: Capsule())
            }
        }
    }
}

// MARK: - AVPlayerLayer-backed view with pinch / pan / double-tap zoom

/// A bare `AVPlayerLayer` view (no transport chrome) that supports pinch-to-zoom,
/// pan-while-zoomed, and double-tap. Zoom is applied as a UIView transform so it
/// survives `AVPlayer` swaps on reconnect (the same UIView is reused; only the
/// layer's `player` is replaced in `updateUIView`).
struct ZoomablePlayerView: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        return view
    }

    func updateUIView(_ view: PlayerLayerUIView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        view.playerLayer.videoGravity = videoGravity
    }
}

final class PlayerLayerUIView: UIView, UIGestureRecognizerDelegate {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    private var scale: CGFloat = 1
    private var offset: CGPoint = .zero
    private let maxScale: CGFloat = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        pinch.delegate = self
        pan.delegate = self
        addGestureRecognizer(pinch)
        addGestureRecognizer(pan)
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .changed {
            let newScale = (scale * gesture.scale).clamped(to: 1...maxScale)
            scale = newScale
            gesture.scale = 1
            applyTransform()
        } else if gesture.state == .ended && scale <= 1.01 {
            resetZoom()
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard scale > 1 else { return }
        let translation = gesture.translation(in: self)
        offset.x += translation.x
        offset.y += translation.y
        gesture.setTranslation(.zero, in: self)
        clampOffset()
        applyTransform()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scale > 1.01 {
            resetZoom()
        } else {
            scale = 2.5
            applyTransform()
        }
    }

    private func applyTransform() {
        clampOffset()
        var transform = CGAffineTransform(scaleX: scale, y: scale)
        transform = transform.translatedBy(x: offset.x / scale, y: offset.y / scale)
        UIView.animate(withDuration: 0.1) { self.transform = transform }
    }

    private func resetZoom() {
        scale = 1
        offset = .zero
        UIView.animate(withDuration: 0.2) { self.transform = .identity }
    }

    private func clampOffset() {
        let maxX = (bounds.width * (scale - 1)) / 2
        let maxY = (bounds.height * (scale - 1)) / 2
        offset.x = offset.x.clamped(to: -maxX...maxX)
        offset.y = offset.y.clamped(to: -maxY...maxY)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
