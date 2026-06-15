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

    private var endObs: NSObjectProtocol?

    /// Load only if nothing is playing yet (idempotent — safe to call from `.task`).
    func loadIfNeeded(client: FrigateClient, url: URL) {
        guard player == nil else { return }
        load(client: client, url: url)
    }

    /// Force (re)load — used by the timeline scrubber to jump to a new moment.
    func load(client: FrigateClient, url: URL) {
        configureAudioSession()
        teardown()

        let item = client.playerItem(for: url)
        // Reuse the existing AVPlayer instance so the bound SwiftUI view swaps content
        // seamlessly when the scrubber jumps to a new time.
        let activePlayer = player ?? AVPlayer()
        activePlayer.replaceCurrentItem(with: item)
        player = activePlayer

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
    }
}
