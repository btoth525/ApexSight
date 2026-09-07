import AVFoundation
import Foundation
import UIKit

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
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var wasPlayingBeforeBackground = false
    /// Bounded auto-retry state for a fresh load — a failure right after a just-fired detection
    /// is often transient (Frigate hasn't finished flushing that segment yet), so a couple of
    /// short-delayed silent retries happen before giving up and showing the error state.
    private var retryAttempt = 0
    private var pendingAutoRetry: Task<Void, Never>?
    /// Fires if the item never reaches .readyToPlay OR .failed (AVPlayer can stall at .unknown
    /// on an empty / late VOD manifest) — routes into the same retry/error path so History shows
    /// a clear "clip unavailable" card instead of an eternal loading shimmer.
    private var stallTimeout: Task<Void, Never>?
    /// True once we took the shared audio session, so we deactivate it on stop/dealloc and
    /// the user's music/podcast resumes instead of staying ducked after viewing a clip.
    private var didActivateAudio = false

    init() {
        // Pause recording playback when the app backgrounds so AVPlayer stops decoding
        // (battery/data) — SwiftUI's onDisappear does NOT fire on backgrounding — then
        // resume on return if it was playing.
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                self.wasPlayingBeforeBackground = player.timeControlStatus != .paused
                player.pause()
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.wasPlayingBeforeBackground else { return }
                self.player?.play()
            }
        })
    }

    deinit {
        // Defensive cleanup if the owning view never called stop(): the block-based
        // NotificationCenter token is NOT auto-removed on dealloc. Both APIs are
        // thread-safe, so this is safe from the nonisolated deinit.
        if let endObs { NotificationCenter.default.removeObserver(endObs) }
        statusObs?.invalidate()
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if didActivateAudio {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Load only if this exact URL isn't already loaded (idempotent — safe to call from
    /// `.task`, which re-runs on every re-appear: returning from a fullscreen expand or a
    /// push used to force a reload that flashed the player AND auto-played ghost audio
    /// while Snapshot mode was showing). A different URL (reused view, new event) loads.
    func loadIfNeeded(client: FrigateClient, url: URL) {
        guard player == nil || lastURL != url else { return }
        load(client: client, url: url)
    }

    /// Jump within the ALREADY-LOADED asset — no reload, no network. This is what makes
    /// repeat scrubs inside one preloaded hour manifest instant: AVPlayer seeks the VOD
    /// segment-accurately with zero server work. Safe before `isReady` (AVPlayerItem
    /// honors a queued seek once loading completes).
    func seek(toOffset seconds: Double, andPlay play: Bool = true) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: CMTime(seconds: 2, preferredTimescale: 600))
        if play { player.play() }
    }

    /// Force (re)load — used by the timeline scrubber to jump to a new moment.
    func load(client: FrigateClient, url: URL) {
        configureAudioSession()
        isReady = false
        hasError = false
        retryAttempt = 0
        pendingAutoRetry?.cancel()
        pendingAutoRetry = nil
        lastURL = url
        lastClient = client
        attachItem(client: client, url: url)
    }

    private func attachItem(client: FrigateClient, url: URL) {
        teardown()
        let item = client.playerItem(for: url)
        // Start with a small forward buffer instead of AVPlayer's generous VOD default —
        // event clips are short and local-network, so waiting to buffer half the clip
        // before the first frame was most of the perceived "loading" time.
        item.preferredForwardBufferDuration = 2
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
                case .readyToPlay:
                    self.isReady = true
                    self.hasError = false
                    self.retryAttempt = 0
                    self.stallTimeout?.cancel()
                    self.stallTimeout = nil
                case .failed:
                    self.handleFailure(client: client, url: url)
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

        // First frame the moment it's decodable — don't wait for the buffer target.
        activePlayer.playImmediately(atRate: 1.0)

        // Backstop: if neither .readyToPlay nor .failed arrives (stuck at .unknown), treat it as
        // a failure so the UI never spins forever on a stream that will never paint.
        stallTimeout?.cancel()
        stallTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled, let self, self.lastURL == url,
                  !self.isReady, !self.hasError else { return }
            self.scheduleAutoRetryOrFail(client: client, url: url)
        }
    }

    private func handleFailure(client: FrigateClient, url: URL) {
        scheduleAutoRetryOrFail(client: client, url: url)
    }

    /// A load failure is often transient right after a fresh detection (the segment isn't
    /// flushed to the recordings index yet) — silently retry twice with a short, growing
    /// delay before surfacing the error state, instead of dead-ending on something that would
    /// very likely resolve itself moments later.
    private func scheduleAutoRetryOrFail(client: FrigateClient, url: URL) {
        guard retryAttempt < 2 else {
            hasError = true
            return
        }
        retryAttempt += 1
        let delaySeconds = retryAttempt == 1 ? 3.0 : 8.0
        pendingAutoRetry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.lastURL == url else { return }
            self.attachItem(client: client, url: url)
        }
    }

    func play() { player?.play() }
    func pause() { player?.pause() }

    /// Re-attempt the last clip after a failure (wired to the error view's Retry button) —
    /// bypasses the auto-retry delay and resets its counter for a clean run.
    func retry() {
        guard let lastClient, let lastURL else { return }
        pendingAutoRetry?.cancel()
        pendingAutoRetry = nil
        retryAttempt = 0
        hasError = false
        attachItem(client: lastClient, url: lastURL)
    }

    func stop() {
        pendingAutoRetry?.cancel()
        pendingAutoRetry = nil
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
        if didActivateAudio {
            didActivateAudio = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        didActivateAudio = true
    }

    private func teardown() {
        stallTimeout?.cancel()
        stallTimeout = nil
        if let endObs { NotificationCenter.default.removeObserver(endObs) }
        endObs = nil
        statusObs?.invalidate()
        statusObs = nil
    }
}
