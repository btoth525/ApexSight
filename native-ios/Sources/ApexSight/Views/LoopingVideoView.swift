import SwiftUI
import AVFoundation
import UIKit

/// A muted, seamlessly-looping HD video preview — the "living photo" for a review card. Plays the
/// event's `/vod/event/<id>` clip (crisp, hardware-decoded) instead of Frigate's dithered
/// `preview.gif`. Authenticated via `FrigateClient.playerItem` (cookie on every segment request),
/// rendered on a Metal-backed `AVPlayerLayer`, matched to the poster's aspect-fit so ultra-wide
/// cameras show the whole scene.
///
/// Loops MANUALLY (seek-to-zero on end) rather than with AVPlayerLooper — the looper needs a
/// finite file-based asset and silently no-ops on an HLS/`.m3u8` stream, which is what the event
/// VOD is (that was the "shows a frame but never plays" bug). Tears down when the row recycles, so
/// a lazy List only ever has a few players alive.
struct LoopingVideoView: UIViewRepresentable {
    let url: URL
    let client: FrigateClient
    var onFirstFrame: (() -> Void)? = nil

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        context.coordinator.attach(url: url, client: client, to: view, onFirstFrame: onFirstFrame)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.attach(url: url, client: client, to: view, onFirstFrame: onFirstFrame)
        }
    }

    static func dismantleUIView(_ view: PlayerLayerView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    final class Coordinator {
        private(set) var url: URL?
        private var player: AVPlayer?
        private var statusObs: NSKeyValueObservation?
        private var endObs: NSObjectProtocol?
        private var firstFrameFired = false

        func attach(url: URL, client: FrigateClient, to view: PlayerLayerView, onFirstFrame: (() -> Void)?) {
            teardown()
            self.url = url
            let item = client.playerItem(for: url)
            let p = AVPlayer(playerItem: item)
            p.isMuted = true
            p.actionAtItemEnd = .none                 // we handle the loop ourselves
            p.automaticallyWaitsToMinimizeStalling = false
            view.playerLayer.player = p
            view.playerLayer.videoGravity = .resizeAspect   // match the poster (uncropped, letterboxed)

            statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
                guard it.status == .readyToPlay else { return }
                DispatchQueue.main.async {
                    p.play()
                    if let self, !self.firstFrameFired { self.firstFrameFired = true; onFirstFrame?() }
                }
            }
            // Loop: HLS VOD fires end-of-playlist; rewind + play again (AVPlayerLooper won't do HLS).
            endObs = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { _ in
                p.seek(to: .zero) { _ in p.play() }
            }
            player = p
            p.play()
        }

        func teardown() {
            statusObs?.invalidate(); statusObs = nil
            if let endObs { NotificationCenter.default.removeObserver(endObs) }; endObs = nil
            player?.pause(); player = nil
            firstFrameFired = false
            url = nil
        }
    }
}
