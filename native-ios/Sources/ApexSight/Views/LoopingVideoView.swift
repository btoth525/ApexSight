import SwiftUI
import AVFoundation
import UIKit

/// A muted, seamlessly-looping HD video preview — the "living photo" for a review card. Plays the
/// event's `/vod/event/<id>` clip (crisp, hardware-decoded) instead of Frigate's dithered
/// `preview.gif`. Authenticated via `FrigateClient.playerItem` (cookie on every segment request),
/// rendered on a Metal-backed `AVPlayerLayer`. Tears its player down when the row recycles, so a
/// lazy `List` only ever has a few playing at once.
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
        private var queue: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var readyObs: NSKeyValueObservation?

        func attach(url: URL, client: FrigateClient, to view: PlayerLayerView, onFirstFrame: (() -> Void)?) {
            teardown()
            self.url = url
            let item = client.playerItem(for: url)
            let q = AVQueuePlayer()
            q.isMuted = true
            q.actionAtItemEnd = .advance
            q.automaticallyWaitsToMinimizeStalling = false
            looper = AVPlayerLooper(player: q, templateItem: item)
            view.playerLayer.player = q
            view.playerLayer.videoGravity = .resizeAspectFill
            readyObs = item.observe(\.status, options: [.new]) { it, _ in
                if it.status == .readyToPlay { DispatchQueue.main.async { onFirstFrame?() } }
            }
            queue = q
            q.play()
        }

        func teardown() {
            readyObs?.invalidate(); readyObs = nil
            queue?.pause()
            looper?.disableLooping()
            looper = nil
            queue = nil
            url = nil
        }
    }
}
