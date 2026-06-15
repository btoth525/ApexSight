import AVFoundation
import SwiftUI

/// A recorded-clip player that supports pinch-to-zoom plus a mute toggle. Used in the
/// Review and Event detail screens so users can zoom into a face / plate / detail in the
/// clip the same way they can on a snapshot.
///
/// Zoom runs on the native `ZoomableScrollView` (UIScrollView) engine — the same one the
/// snapshots use — so pinch / double-tap / pan are buttery smooth with momentum, instead of
/// the finicky SwiftUI gesture path.
struct ZoomableClipPlayer: View {
    let player: AVPlayer
    @State private var muted = false

    var body: some View {
        ZoomableScrollView {
            VideoLayerView(player: player)
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                muted.toggle()
                player.isMuted = muted
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .black))
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
                    .foregroundStyle(.white)
            }
            .padding(8)
        }
    }
}

/// A bare AVPlayerLayer host (no transport chrome) so the clip can be freely zoomed.
struct VideoLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerLayerHostView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

final class PlayerLayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }
}
