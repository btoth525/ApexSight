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
    /// When true, start on the lighter `_sub` stream and stay there (grid/cards) for a
    /// fast first frame and low CPU; the fullscreen player leaves this false for HD.
    private var preferSub = false
    /// Frigate-style quality ramp: start on SD (sub) for an instant picture, then
    /// silently preload HD (main) and hot-swap to it once it's ready — and stay on HD.
    private var autoUpgrade = false
    private var upgraded = false
    private var didAttemptUpgrade = false
    private var upgradePlayer: AVPlayer?          // hidden player that buffers HD before the swap
    private var upgradeItemObs: NSKeyValueObservation?

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

    func start(preferSub: Bool = false, autoUpgrade: Bool = false) {
        self.preferSub = preferSub
        self.autoUpgrade = autoUpgrade
        upgraded = false
        didAttemptUpgrade = false
        isStopped = false
        retryCount = 0
        didTryReauth = false
        usingFallback = preferSub   // grid/cards begin on the sub-stream for a fast start
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
        cancelUpgrade()
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
        usingFallback = preferSub
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

        attachObservers(to: item, player: newPlayer)
        newPlayer.play()
    }

    /// Wires status/playback observers — shared by the initial connect and the HD swap.
    private func attachObservers(to item: AVPlayerItem, player: AVPlayer) {
        statusObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                self.handleStatus(item)
            }
        }
        timeControlObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, !self.isStopped else { return }
                if player.timeControlStatus == .playing {
                    self.state = .playing
                    self.retryCount = 0
                    self.didTryReauth = false
                    self.beginUpgradeIfNeeded()
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
    }

    // MARK: - SD → HD upgrade (Frigate-style quality ramp)

    /// Once the SD stream is playing, silently buffer HD in a hidden player.
    private func beginUpgradeIfNeeded() {
        guard autoUpgrade, !upgraded, !didAttemptUpgrade, usingFallback else { return }
        guard let makeItem, let mainURL = makeURL?(), let mainItem = makeItem(mainURL) else { return }
        didAttemptUpgrade = true
        mainItem.preferredForwardBufferDuration = 2
        let preloader = AVPlayer(playerItem: mainItem)
        preloader.automaticallyWaitsToMinimizeStalling = false
        preloader.isMuted = true
        upgradePlayer = preloader
        upgradeItemObs = mainItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, !self.isStopped, !self.upgraded else { return }
                switch item.status {
                case .readyToPlay: self.finishUpgrade(to: item)
                case .failed:      self.cancelUpgrade()   // HD unavailable → stay on crisp SD
                default:           break
                }
            }
        }
        preloader.play()   // drives the HD item to readyToPlay
    }

    /// HD is buffered and ready — promote the hidden HD player to the visible one and
    /// retire the SD player. (Promoting the player keeps each item with a single player,
    /// which is far more reliable than moving an item between players.)
    private func finishUpgrade(to mainItem: AVPlayerItem) {
        guard let preloader = upgradePlayer else { cancelUpgrade(); return }
        upgradeItemObs?.invalidate(); upgradeItemObs = nil
        let oldPlayer = player
        teardownObservers()                 // drop the SD item's observers
        preloader.isMuted = isMuted
        preloader.actionAtItemEnd = .none
        player = preloader                  // the view rebinds to the HD player; state stays .playing
        upgradePlayer = nil
        usingFallback = false
        upgraded = true
        attachObservers(to: mainItem, player: preloader)
        preloader.play()
        oldPlayer?.pause()                  // stop the SD decoder
    }

    private func cancelUpgrade() {
        upgradeItemObs?.invalidate(); upgradeItemObs = nil
        upgradePlayer?.replaceCurrentItem(with: nil)
        upgradePlayer = nil
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

        // We deliberately started on the sub-stream but it won't come up (e.g. the camera
        // has no `_sub` stream) — fall FORWARD to the main stream so it still plays.
        if usingFallback, preferSub, retryCount >= 3 {
            usingFallback = false
            preferSub = false          // main is the base now; don't bounce back to sub
            didAttemptUpgrade = true   // already on main; no separate HD upgrade needed
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
    /// Grid/card cells pass `true` to start on the lighter sub-stream (fast + low CPU).
    var preferSubStream: Bool = false
    /// Fullscreen passes `true`: start on SD for an instant picture, then auto-upgrade to
    /// HD and stay there (Frigate-style). Pair with `preferSubStream: true`.
    var autoUpgradeToHD: Bool = false
    /// Delay before the live player spins up. Cards use a short delay so fast scrolling
    /// shows only the cached snapshot and never thrashes AVPlayers for cells you pass.
    var startDelay: Double = 0
    var onPlaying: ((Bool) -> Void)? = nil

    @StateObject private var model = HLSLiveModel()
    @State private var startTask: Task<Void, Never>?

    private var isPlaying: Bool { model.state == .playing }

    /// The AVPlayer layer. In the fullscreen player (`showControls`) it's wrapped in a
    /// `ZoomableScrollView` for smooth native pinch / double-tap / pan zoom (the same engine
    /// the snapshots and clips use). In grid/card cells it's a plain, non-interactive layer.
    @ViewBuilder
    private func playerLayer(_ player: AVPlayer) -> some View {
        if showControls {
            ZoomableScrollView {
                ZoomablePlayerView(player: player)
            }
            .opacity(isPlaying ? 1 : 0)
            .animation(.easeIn(duration: 0.3), value: isPlaying)
            .allowsHitTesting(true)
        } else {
            ZoomablePlayerView(player: player)
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
            // Downscaled to a shared size so the card and the fullscreen placeholder are
            // a cache hit — tapping a camera shows its frame instantly (Reolink-style).
            if let url = appState.client?.latestFrameURL(camera: camera.name, height: 540) {
                RemoteImage(url: url, contentMode: showControls ? .fit : .fill)
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
                        Text("Connecting…")
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
            // Debounced start: while scrolling, a cell that appears and disappears within
            // the delay never starts a player — so the wall scrolls smoothly on snapshots
            // and only goes live once it settles.
            startTask?.cancel()
            startTask = Task { @MainActor in
                if startDelay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(startDelay * 1_000_000_000))
                }
                if !Task.isCancelled { model.start(preferSub: preferSubStream, autoUpgrade: autoUpgradeToHD) }
            }
        }
        .onDisappear {
            startTask?.cancel()
            model.stop()
        }
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

final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }
}
