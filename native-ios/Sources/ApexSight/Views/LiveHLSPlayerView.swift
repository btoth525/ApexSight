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
    private var lifecycleObservers: [NSObjectProtocol] = []

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
        observeLifecycle()
        connect()
    }

    /// Pause decoding when the app backgrounds (SwiftUI `onDisappear` does NOT fire on
    /// backgrounding, so without this the AVPlayer keeps pulling + decoding HLS — wasted
    /// battery/data, and a stale frame on return). Rebuild a fresh stream on foreground.
    private func observeLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                self.reconnectTask?.cancel(); self.reconnectTask = nil
                self.player?.pause()
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                // The live edge moved on while suspended — reconnect fresh rather than
                // resuming a stale buffer.
                self.retryCount = 0
                self.didTryReauth = false
                self.connect()
            }
        })
    }

    private func teardownLifecycle() {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers.removeAll()
    }

    func stop() {
        isStopped = true
        teardownLifecycle()
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
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                self.handleStatus(item)
            }
        }
        timeControlObs = newPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
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
    /// Pass a controller to enable PiP for this player from outside (e.g. a camera-wall
    /// cell's long-press menu). When nil, the single-camera view uses its own.
    var pipController: LivePiPController? = nil
    /// Single tap on the video (full-screen view) — used to toggle immersive chrome.
    var onSingleTap: (() -> Void)? = nil
    var onPlaying: ((Bool) -> Void)? = nil

    @StateObject private var model = HLSLiveModel()
    @StateObject private var ownPiP = LivePiPController()
    private var pip: LivePiPController { pipController ?? ownPiP }
    @State private var fillMode = false

    private var isPlaying: Bool { model.state == .playing }

    /// The AVPlayer layer. In the fullscreen player (`showControls`) it's wrapped in a
    /// `ZoomableScrollView` for smooth native pinch / double-tap / pan zoom (the same engine
    /// the snapshots and clips use). In grid/card cells it's a plain, non-interactive layer.
    @ViewBuilder
    private func playerLayer(_ player: AVPlayer) -> some View {
        if showControls {
            ZoomableScrollView(onSingleTap: onSingleTap) {
                ZoomablePlayerView(
                    player: player,
                    videoGravity: fillMode ? .resizeAspectFill : .resizeAspect,
                    pip: pip,
                    autoPiP: true
                )
            }
            .opacity(isPlaying ? 1 : 0)
            .animation(.easeIn(duration: 0.3), value: isPlaying)
            .allowsHitTesting(true)
        } else {
            // Wall cells: wire PiP only when a controller was provided (long-press menu).
            ZoomablePlayerView(player: player, pip: pipController, autoPiP: false)
                .opacity(isPlaying ? 1 : 0)
                .animation(.easeIn(duration: 0.3), value: isPlaying)
                .allowsHitTesting(false)
        }
    }

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
            // Pinch / pan / double-tap zoom handled via SwiftUI gestures when showControls.
            if let player = model.player {
                playerLayer(player)
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
                liveControls
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

    private var liveControls: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Spacer()
                Button {
                    Haptics.tap()
                    fillMode.toggle()
                } label: {
                    Image(systemName: fillMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .black))
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(fillMode ? "Fit to screen" : "Fill screen")
                if pip.isSupported {
                    Button {
                        Haptics.tap()
                        pip.toggle()
                    } label: {
                        Image(systemName: pip.isActive ? "pip.exit" : "pip.enter")
                            .font(.system(size: 14, weight: .black))
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel(pip.isActive ? "Exit Picture in Picture" : "Picture in Picture")
                }
                Button {
                    Haptics.tap()
                    model.toggleMute()
                } label: {
                    Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 14, weight: .black))
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(model.isMuted ? "Unmute" : "Mute")
            }
            .padding(.trailing, 14)
            .padding(.bottom, 8)
        }
        // Only the buttons are tappable — the rest passes zoom gestures through.
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

// MARK: - Picture in Picture

/// Drives Picture in Picture for a live `AVPlayerLayer`. SwiftUI holds one of these,
/// passes it to `ZoomablePlayerView`, and toggles PiP from a button.
@MainActor
final class LivePiPController: ObservableObject {
    @Published var isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    @Published var isPossible = false
    @Published var isActive = false
    fileprivate weak var controller: AVPictureInPictureController?

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        }
    }
}

// MARK: - AVPlayerLayer view with pinch / pan / double-tap zoom (+ optional PiP)

struct ZoomablePlayerView: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    /// When set, Picture in Picture is wired to this layer and surfaced through the controller.
    var pip: LivePiPController? = nil
    /// Float into PiP automatically when the app backgrounds while this is playing inline.
    var autoPiP: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(pip: pip, autoPiP: autoPiP) }

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        context.coordinator.attach(to: view.playerLayer)
        return view
    }

    func updateUIView(_ view: PlayerLayerUIView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        view.playerLayer.videoGravity = videoGravity
    }

    final class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
        private let pip: LivePiPController?
        private let autoPiP: Bool
        private var controller: AVPictureInPictureController?
        private var possibleObs: NSKeyValueObservation?

        init(pip: LivePiPController?, autoPiP: Bool) {
            self.pip = pip
            self.autoPiP = autoPiP
        }

        // Called from makeUIView (main thread). State is pushed to the @MainActor
        // controller via Task to keep concurrency clean across Swift versions.
        func attach(to layer: AVPlayerLayer) {
            // AVPictureInPictureController(playerLayer:) is failable on some SDKs.
            guard pip != nil, controller == nil,
                  AVPictureInPictureController.isPictureInPictureSupported(),
                  let controller = AVPictureInPictureController(playerLayer: layer) else { return }
            controller.canStartPictureInPictureAutomaticallyFromInline = autoPiP
            controller.delegate = self
            self.controller = controller
            let pip = self.pip
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor in
                pip?.controller = controller
                pip?.isPossible = possible
            }
            possibleObs = controller.observe(\.isPictureInPicturePossible, options: [.new]) { c, _ in
                let value = c.isPictureInPicturePossible
                Task { @MainActor in pip?.isPossible = value }
            }
        }

        func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
            let pip = self.pip
            Task { @MainActor in pip?.isActive = true }
        }

        func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
            let pip = self.pip
            Task { @MainActor in pip?.isActive = false }
        }
    }
}

final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }
}
