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

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspectFill
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

    func makeUIView(context: Context) -> GridPlayerUIView {
        let view = GridPlayerUIView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: GridPlayerUIView, context: Context) {
        if uiView.player !== player {
            uiView.player = player
        }
    }
}
