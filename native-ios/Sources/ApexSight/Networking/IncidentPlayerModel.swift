import AVFoundation
import Foundation
import UIKit

/// Plays an incident's clips **back-to-back as one continuous reel** (HomeKit-style) using an
/// `AVQueuePlayer` — no re-encoding, so it works for every camera/codec on device (the streaming
/// decoder, same one that plays your live cameras). Each leg is one authenticated HLS item; the
/// queue auto-advances and we track which leg is on screen so the filmstrip can follow.
@MainActor
final class IncidentPlayerModel: ObservableObject {
    @Published private(set) var currentIndex = 0
    @Published private(set) var isPlaying = true

    let player = AVQueuePlayer()

    private var legs: [FrigateEvent] = []
    private var client: FrigateClient?
    private var indexForItem: [ObjectIdentifier: Int] = [:]
    private var currentItemObs: NSKeyValueObservation?
    private var rateObs: NSKeyValueObservation?
    private var configured = false
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var wasPlayingBeforeBackground = false
    /// True once we took the shared audio session, so we deactivate it on teardown/dealloc and
    /// the user's music/podcast resumes instead of staying ducked after a reel.
    private var didActivateAudio = false

    init() {
        // Pause the reel when the app backgrounds — SwiftUI's onDisappear does NOT fire on
        // backgrounding, so without this the AVQueuePlayer keeps decoding and its `.playback`
        // session stays active (audio behind the lock screen, battery/data drain). Resume on
        // return if it was playing. Mirrors ClipPlayerModel / HLSLivePlayerView.
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.wasPlayingBeforeBackground = self.player.timeControlStatus != .paused
                self.player.pause()
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.wasPlayingBeforeBackground else { return }
                self.player.play()
            }
        })
    }

    deinit {
        // Defensive cleanup if the owning view never called teardown(): block-based NC tokens are
        // NOT auto-removed on dealloc. Both APIs are thread-safe, so this is safe from the
        // nonisolated deinit. (KVO auto-invalidates on dealloc.)
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        if didActivateAudio {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func configure(legs: [FrigateEvent], client: FrigateClient) {
        guard !configured else { return }
        configured = true
        self.legs = legs
        self.client = client
        configureAudioSession()
        buildQueue(from: 0)

        currentItemObs = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, let item = player.currentItem,
                      let idx = self.indexForItem[ObjectIdentifier(item)] else { return }
                self.currentIndex = idx
            }
        }
        rateObs = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in self?.isPlaying = player.rate > 0 }
        }
        player.playImmediately(atRate: 1.0)
    }

    /// (Re)build the queue starting at a leg — used on load and when the filmstrip jumps.
    private func buildQueue(from start: Int) {
        player.removeAllItems()
        indexForItem.removeAll()
        guard let client, legs.indices.contains(start) else { return }
        for i in start..<legs.count {
            let url = client.eventVodURL(id: legs[i].id)   // HLS VOD — the reliable playback path
            let item = client.playerItem(for: url)
            // Small forward buffer per leg — clips are short + local, start on first frames.
            item.preferredForwardBufferDuration = 2
            indexForItem[ObjectIdentifier(item)] = i
            player.insert(item, after: nil)
        }
        currentIndex = start
    }

    func jump(to index: Int) {
        buildQueue(from: index)
        player.playImmediately(atRate: 1.0)
    }

    func togglePlay() {
        if player.rate > 0 { player.pause() } else { player.play() }
    }

    func teardown() {
        currentItemObs = nil
        rateObs = nil
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObservers.removeAll()
        player.pause()
        player.removeAllItems()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        didActivateAudio = true
    }
}
