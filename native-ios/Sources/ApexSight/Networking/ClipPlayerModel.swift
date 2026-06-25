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
                if item.status == .readyToPlay { self.isReady = true }
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

    func stop() {
        teardown()
        isReady = false
        player?.pause()
        player = nil
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
