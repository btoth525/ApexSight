import AVFoundation
import SwiftUI

/// Wraps any content with pinch-to-zoom, pan, and double-tap zoom — with strict clamping
/// so the content can never be panned or shrunk off-screen. Fixes the "zoom in → pan →
/// zoom out → video drifts off-screen and goes black" bug: the pan offset is always
/// re-clamped to the current scale, and zooming back to 1× snaps cleanly to center.
///
/// The pan gesture is only active while zoomed in, so it never blocks scrolling when the
/// content sits inside a ScrollView (e.g. the Review / Event detail cards).
struct ZoomableContainer<Content: View>: View {
    @ViewBuilder var content: Content

    @State private var scale: CGFloat = 1
    @State private var startScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var startOffset: CGSize = .zero

    private let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            zoomBody(geo.size)
        }
    }

    @ViewBuilder
    private func zoomBody(_ size: CGSize) -> some View {
        let base = content
            .scaleEffect(scale)
            .offset(offset)
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(magnification(size))
            .onTapGesture(count: 2) { toggleZoom() }
            .clipped()

        // Only attach the pan gesture while zoomed, so it never swallows page scrolling.
        if scale > 1.01 {
            base.simultaneousGesture(pan(size))
        } else {
            base
        }
    }

    private func magnification(_ size: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = clampScale(startScale * value)
                offset = clampOffset(offset, size: size)
            }
            .onEnded { _ in
                if scale <= 1.01 {
                    resetZoom()
                } else {
                    startScale = scale
                    startOffset = offset
                }
            }
    }

    private func pan(_ size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let proposed = CGSize(
                    width: startOffset.width + value.translation.width,
                    height: startOffset.height + value.translation.height
                )
                offset = clampOffset(proposed, size: size)
            }
            .onEnded { _ in startOffset = offset }
    }

    private func toggleZoom() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            if scale > 1.01 {
                resetZoom()
            } else {
                scale = 2.5
                startScale = 2.5
                offset = .zero
                startOffset = .zero
            }
        }
    }

    private func resetZoom() {
        scale = 1
        startScale = 1
        offset = .zero
        startOffset = .zero
    }

    private func clampScale(_ value: CGFloat) -> CGFloat {
        min(max(value, 1), maxScale)
    }

    /// Clamp the offset so the scaled content's edges can never move inside the frame.
    private func clampOffset(_ value: CGSize, size: CGSize) -> CGSize {
        guard scale > 1 else { return .zero }
        let maxX = (size.width * (scale - 1)) / 2
        let maxY = (size.height * (scale - 1)) / 2
        return CGSize(
            width: min(max(value.width, -maxX), maxX),
            height: min(max(value.height, -maxY), maxY)
        )
    }
}

/// A recorded-clip player that supports pinch-to-zoom (via `ZoomableContainer`) plus a
/// mute toggle. Used in the Review and Event detail screens so users can zoom into a
/// face / plate / detail in the clip the same way they can on a snapshot.
struct ZoomableClipPlayer: View {
    let player: AVPlayer
    @State private var muted = false

    var body: some View {
        ZoomableContainer {
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
