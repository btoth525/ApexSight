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
                    .liquidGlass(in: Circle(), interactive: true, fallbackMaterial: .ultraThinMaterial)
                    .foregroundStyle(.white)
                    .hitTarget()
            }
            .accessibilityLabel(muted ? "Unmute" : "Mute")
            .padding(8)
        }
    }
}

/// A lightweight loading skeleton for video surfaces — a soft shimmer over a dark base so a
/// clip that's still buffering reads as "loading," never a dead black rectangle. Respects
/// Reduce Motion (falls back to a calm spinner with no sweep).
struct ClipSkeleton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if !reduceMotion {
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.12), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: geo.size.width)
                    .offset(x: sweep ? geo.size.width : -geo.size.width)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false), value: sweep)
                }
                ProgressView()
                    .tint(GlassTheme.cyan)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { sweep = true }
        .allowsHitTesting(false)
    }
}

/// Renders a clip player that holds a loading skeleton over itself until the model reports a
/// real frame is ready, then crossfades the video in. Centralizes the "never a black box,
/// smooth reveal" behavior every clip surface wants.
struct LoadingClipPlayer: View {
    @ObservedObject var model: ClipPlayerModel

    var body: some View {
        ZStack {
            if let player = model.player {
                ZoomableClipPlayer(player: player)
                    .opacity(model.isReady ? 1 : 0)
                    .animation(.easeIn(duration: 0.25), value: model.isReady)
            }
            if model.hasError {
                ClipErrorView(retry: model.retry)
            } else if !model.isReady {
                ClipSkeleton().transition(.opacity)
            }
        }
    }
}

/// Shown when a clip can't load (no recording for that time, auth, server down) — a clear
/// dead-end message + Retry instead of a skeleton that spins forever. Shared by every clip
/// surface (`LoadingClipPlayer` and `RecordingBrowserView`) so a failed VOD load is never
/// silently invisible.
struct ClipErrorView: View {
    let retry: () -> Void

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: GlassTheme.Space.m) {
                Image(systemName: "film.stack")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.orange)
                Text("Clip unavailable")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.white)
                Text("No recording for this moment, or the server didn't respond.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, GlassTheme.Space.xxl)
                Button(action: retry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.black)
                        .padding(.horizontal, GlassTheme.Space.l)
                        .padding(.vertical, 9)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
            }
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
