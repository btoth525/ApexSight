import AVFoundation
import Foundation

/// Plays a recorded clip via Frigate's VOD HLS playlist (`master.m3u8`).
///
/// Per Frigate's docs this is the correct, iOS-recommended way to play recordings —
/// AVPlayer handles HLS reliably, whereas the progressive `clip.mp4` export is not
/// recommended for iOS. Reuses the SAME `FrigateClient.playerItem(for:)` auth path as
/// the live stream (cookie-seeded `frigate_token` + Bearer header). Loops on completion.
@MainActor
final class ClipPlayerModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    /// True once the current item is actually ready to show a frame — so the UI can hold a
    /// loading skeleton over the player until there's real video, instead of a black box.
    @Published private(set) var isReady = false
    /// True if the item failed to load (404 / no recording / auth) — so the UI shows a clear
    /// error + retry instead of a skeleton that spins forever.
    @Published private(set) var hasError = false

    private var lastURL: URL?
    private var lastClient: FrigateClient?
    private var endObs: NSObjectProtocol?
    private var statusObs: NSKeyValueObservation?

    /// Load only if nothing is playing yet (idempotent — safe to call from `.task`).
    func loadIfNeeded(client: FrigateClient, url: URL) {
        guard player == nil else { return }
        load(client: client, url: url)
    }

    /// Force (re)load — used by the timeline scrubber to jump to a new moment.
    func load(client: FrigateClient, url: URL) {
        configureAudioSession()
        teardown()
        isReady = false
        hasError = false
        lastURL = url
        lastClient = client

        let item = client.playerItem(for: url)
        // Reuse the existing AVPlayer instance so the bound SwiftUI view swaps content
        // seamlessly when the scrubber jumps to a new time.
        let activePlayer = player ?? AVPlayer()
        activePlayer.replaceCurrentItem(with: item)
        player = activePlayer

        // Reveal the video only when the item can actually present a frame. `.initial` covers
        // the rare case where the item is already ready by the time we attach.
        statusObs = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay: self.isReady = true; self.hasError = false
                case .failed: self.hasError = true
                default: break
                }
            }
        }

        endObs = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.player?.seek(to: .zero)
                self?.player?.play()
            }
        }

        activePlayer.play()
    }

    func play() { player?.play() }
    func pause() { player?.pause() }

    /// Re-attempt the last clip after a failure (wired to the error view's Retry button).
    func retry() {
        guard let lastClient, let lastURL else { return }
        load(client: lastClient, url: lastURL)
    }

    func stop() {
        teardown()
        isReady = false
        hasError = false
        // Detach the item before dropping the player so AVFoundation releases the asset and its
        // decoder immediately, rather than holding the buffered clip until ARC gets around to it.
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        // Clear the retry references too — a deliberately stopped surface must not be able to
        // resurrect a clip from a stale Retry tap after it's gone.
        lastURL = nil
        lastClient = nil
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func teardown() {
        if let endObs { NotificationCenter.default.removeObserver(endObs) }
        endObs = nil
        statusObs?.invalidate()
        statusObs = nil
    }
}
