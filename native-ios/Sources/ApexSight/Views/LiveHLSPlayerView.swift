import AVKit
import AVFoundation
import SwiftUI
import UIKit

// MARK: - Stream rules

enum LiveStreamRules {
    /// Returns true for cameras that must always use the sub-stream (confirmed H.265 main
    /// that iOS AVPlayer can't decode). Currently none — all cameras start on main and fall
    /// back to sub after 3 consecutive failures.
    static func forcesSubStream(_ camera: String) -> Bool { false }
}

// MARK: - Live HLS model

/// Owns one tuned-for-live `AVPlayer`, watches for stalls/failures, and rebuilds with
/// exponential-backoff reconnect. On the first failure it tries a silent token refresh
/// before backoff. After 3 main-stream failures it downgrades to the sub-stream.
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
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try? AVAudioSession.sharedInstance().setActive(true)
        }
        player?.isMuted = isMuted
    }

    func reload() {
        retryCount = 0
        didTryReauth = false
        usingFallback = false
        connect()
    }

    private func connect() {
        let urlSource = (usingFallback ? makeSubURL : makeURL) ?? makeURL
        guard !isStopped, let makeItem, let url = urlSource?(), let item = makeItem(url) else { return }
        teardownObservers()
        player?.pause()

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
            let msg = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "Playback failed"
            Task { @MainActor in self?.handleFailure(msg) }
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
        if !didTryReauth, let reauth {
            didTryReauth = true
            Task { @MainActor in
                if await reauth() { connect() } else { scheduleReconnect(reason: message) }
            }
        } else {
            scheduleReconnect(reason: message)
        }
    }

    private func scheduleReconnect(reason: String) {
        guard !isStopped, reconnectTask == nil else { return }
        retryCount += 1

        // After 3 main-stream failures silently downgrade to sub-stream.
        if !usingFallback, retryCount >= 3, makeSubURL != nil {
            usingFallback = true
            retryCount = 0
            didTryReauth = false
            state = .connecting
            reconnectTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run { self?.reconnectTask = nil; self?.connect() }
            }
            return
        }

        guard retryCount <= 6 else { state = .failed(reason); return }
        state = .connecting
        let delay = min(pow(2.0, Double(retryCount - 1)), 16)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run { self?.reconnectTask = nil; self?.connect() }
        }
    }

    private func teardownObservers() {
        statusObs?.invalidate(); statusObs = nil
        timeControlObs?.invalidate(); timeControlObs = nil
        if let stallObs { NotificationCenter.default.removeObserver(stallObs) }; stallObs = nil
        if let failObs { NotificationCenter.default.removeObserver(failObs) }; failObs = nil
    }
}

// MARK: - Live HLS view

struct HLSLivePlayerView: View {
    @EnvironmentObject private var appState: AppState
    let camera: FrigateCamera
    var showControls: Bool = false
    var onPlaying: ((Bool) -> Void)? = nil

    @StateObject private var model = HLSLiveModel()

    private var isPlaying: Bool { model.state == .playing }

    var body: some View {
        ZStack {
            Color.black

            // Snapshot placeholder — shows instantly so there's never a black gap.
            // Sits behind the video layer and fades out the moment the stream is live.
            // Never hit-testable so it can't swallow the player's zoom gestures.
            if let url = appState.client?.latestFrameURL(camera: camera.name) {
                RemoteImage(url: url, contentMode: .fit)
                    .opacity(isPlaying ? 0 : 1)
                    .animation(.easeOut(duration: 0.4), value: isPlaying)
                    .allowsHitTesting(false)
            }

            // AVPlayer layer — invisible until actually playing, then fades in cleanly.
            // Pinch / pan / double-tap zoom live in PlayerLayerUIView. Hit-testing is
            // enabled only when controls are shown (fullscreen), so grid/card taps still
            // pass through to the NavigationLink underneath.
            if let player = model.player {
                ZoomablePlayerView(player: player)
                    .opacity(isPlaying ? 1 : 0)
                    .animation(.easeIn(duration: 0.3), value: isPlaying)
                    .allowsHitTesting(showControls)
            }

            // Subtle connecting pill at the bottom — non-intrusive, out of the way.
            if model.state == .connecting {
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        ProgressView().tint(.white).scaleEffect(0.65)
                        Text(model.usingFallback ? "Reconnecting…" : "Connecting…")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.bottom, 14)
                }
                .allowsHitTesting(false)
            }

            if case .failed(let message) = model.state {
                failureOverlay(message)
            }

            if showControls {
                muteButton
            }
        }
        .onAppear {
            model.configure(
                makeURL: { appState.client?.liveHLSURL(camera: camera.name, sub: false) },
                makeSubURL: { appState.client?.liveHLSURL(camera: camera.name, sub: true) },
                makeItem: { url in appState.client?.playerItem(for: url) },
                reauth: { await appState.reauthenticate() }
            )
            model.start()
        }
        .onDisappear { model.stop() }
        .onChange(of: model.state) { _, newState in
            onPlaying?(newState == .playing)
        }
    }

    private var muteButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button { model.toggleMute() } label: {
                    Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 14, weight: .black))
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                        .foregroundStyle(.white)
                }
                .padding(.trailing, 14)
                .padding(.bottom, 8)
            }
        }
        // Only the button itself is tappable — the rest passes zoom gestures through.
        .allowsHitTesting(true)
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
            Button { model.reload() } label: {
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

// MARK: - AVPlayerLayer view with pinch / pan / double-tap zoom

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
        backgroundColor = .clear
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

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        if g.state == .changed {
            scale = (scale * g.scale).clamped(to: 1...maxScale)
            g.scale = 1
            applyTransform()
        } else if g.state == .ended && scale <= 1.01 {
            resetZoom()
        }
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard scale > 1 else { return }
        let t = g.translation(in: self)
        offset.x += t.x; offset.y += t.y
        g.setTranslation(.zero, in: self)
        clampOffset()
        applyTransform()
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        if scale > 1.01 { resetZoom() } else { scale = 2.5; applyTransform() }
    }

    private func applyTransform() {
        clampOffset()
        var t = CGAffineTransform(scaleX: scale, y: scale)
        t = t.translatedBy(x: offset.x / scale, y: offset.y / scale)
        UIView.animate(withDuration: 0.1) { self.transform = t }
    }

    private func resetZoom() {
        scale = 1; offset = .zero
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
