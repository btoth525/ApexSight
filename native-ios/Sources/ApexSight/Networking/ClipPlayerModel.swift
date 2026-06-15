import AVFoundation
import Foundation

/// Plays a recorded clip with automatic source fallback so playback "just works"
/// across any Frigate configuration.
///
/// Primary source is the VOD HLS manifest (`/vod/.../master.m3u8`) — the same source
/// Frigate's own web UI uses, and the most reliable way to stream a recording to
/// AVPlayer (proper segmenting, fast start). If that item fails to load or play, the
/// model transparently retries with the progressive MP4 export
/// (`/api/{camera}/start/.../end/.../clip.mp4`). The clip loops on completion.
///
/// Reuses the SAME `FrigateClient.playerItem(for:)` auth path as the live stream
/// (cookie-seeded `frigate_token` + Bearer header), which is already proven to work.
@MainActor
final class ClipPlayerModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var failed = false

    private var client: FrigateClient?
    private var fallbackURL: URL?
    private var usedFallback = false

    private var statusObs: NSKeyValueObservation?
    private var endObs: NSObjectProtocol?
    private var failObs: NSObjectProtocol?

    /// Load only if nothing is playing yet (idempotent — safe to call from `.task`).
    func loadIfNeeded(client: FrigateClient, primary: URL, fallback: URL?) {
        guard player == nil else { return }
        load(client: client, primary: primary, fallback: fallback)
    }

    /// Force (re)load a new clip — used by the timeline scrubber to jump to a new moment.
    func load(client: FrigateClient, primary: URL, fallback: URL?) {
        self.client = client
        self.fallbackURL = fallback
        usedFallback = false
        failed = false
        configureAudioSession()
        play(url: primary)
    }

    func play() { player?.play() }
    func pause() { player?.pause() }

    func stop() {
        teardownObservers()
        player?.pause()
        player = nil
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func play(url: URL) {
        guard let client else { return }
        teardownObservers()

        let item = client.playerItem(for: url)
        // Reuse the existing AVPlayer instance when present so the bound SwiftUI view
        // swaps content seamlessly (important for scrub + HLS→MP4 fallback).
        let activePlayer = player ?? AVPlayer()
        activePlayer.replaceCurrentItem(with: item)
        player = activePlayer

        statusObs = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor in self?.handleStatus(observedItem) }
        }
        endObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.player?.seek(to: .zero)
                self?.player?.play()
            }
        }
        failObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleFailure() }
        }

        activePlayer.play()
    }

    private func handleStatus(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            player?.play()
        case .failed:
            handleFailure()
        default:
            break
        }
    }

    private func handleFailure() {
        if !usedFallback, let fallbackURL {
            usedFallback = true
            play(url: fallbackURL)   // HLS failed → retry the progressive MP4
        } else {
            failed = true
        }
    }

    private func teardownObservers() {
        statusObs?.invalidate(); statusObs = nil
        if let endObs { NotificationCenter.default.removeObserver(endObs) }; endObs = nil
        if let failObs { NotificationCenter.default.removeObserver(failObs) }; failObs = nil
    }
}
