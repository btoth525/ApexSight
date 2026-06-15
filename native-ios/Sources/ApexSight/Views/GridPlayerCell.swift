import AVFoundation
import SwiftUI
import UIKit

/// Lightweight single-camera cell for the multi-camera grid.
/// Uses AVPlayerLayer directly to support many simultaneous streams without PiP conflicts.
final class GridPlayerUIView: UIView {
    private let playerLayer = AVPlayerLayer()

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    var gravity: AVLayerVideoGravity {
        get { playerLayer.videoGravity }
        set { playerLayer.videoGravity = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}

struct GridPlayerCell: UIViewRepresentable {
    let player: AVPlayer
    /// `.resizeAspect` (default) shows the whole frame — no sides cut off.
    /// `.resizeAspectFill` fills the tile (used by the full-screen wall).
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> GridPlayerUIView {
        let view = GridPlayerUIView()
        view.player = player
        view.gravity = gravity
        return view
    }

    func updateUIView(_ uiView: GridPlayerUIView, context: Context) {
        if uiView.player !== player {
            uiView.player = player
        }
        uiView.gravity = gravity
    }
}
