import AVFoundation
import Foundation

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
        player.play()
    }

    /// (Re)build the queue starting at a leg — used on load and when the filmstrip jumps.
    private func buildQueue(from start: Int) {
        player.removeAllItems()
        indexForItem.removeAll()
        guard let client, legs.indices.contains(start) else { return }
        for i in start..<legs.count {
            let url = client.eventVodURL(id: legs[i].id)   // HLS VOD — the reliable playback path
            let item = client.playerItem(for: url)
            indexForItem[ObjectIdentifier(item)] = i
            player.insert(item, after: nil)
        }
        currentIndex = start
    }

    func jump(to index: Int) {
        buildQueue(from: index)
        player.play()
    }

    func togglePlay() {
        if player.rate > 0 { player.pause() } else { player.play() }
    }

    func teardown() {
        currentItemObs = nil
        rateObs = nil
        player.pause()
        player.removeAllItems()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}
