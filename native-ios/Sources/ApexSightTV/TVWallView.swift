import AVKit
import SwiftUI

/// The big-screen command center: a live wall of every camera. When Frigate detects
/// something, that tile glows and pops (Smart Focus). Play/Pause on the Siri Remote
/// toggles 2-up / 3-up density.
struct TVWallView: View {
    @EnvironmentObject private var state: TVAppState
    @State private var columns = 2

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 18), count: columns)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if state.cameras.isEmpty {
                VStack(spacing: 16) {
                    ProgressView().scaleEffect(2)
                    Text("Loading cameras…").foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: 18) {
                        ForEach(state.cameras) { camera in
                            TVCameraTile(camera: camera, active: state.activeCamera == camera.name)
                        }
                    }
                    .padding(50)
                }
            }
        }
        .onPlayPauseCommand { columns = (columns == 2) ? 3 : 2 }
    }
}

private struct TVCameraTile: View {
    @EnvironmentObject private var state: TVAppState
    let camera: FrigateCamera
    let active: Bool

    private var displayName: String {
        camera.name.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            if let client = state.client {
                TVPlayerView(url: client.liveHLSURL(camera: camera.name)) { client.playerItem(for: $0) }
            }
            LinearGradient(colors: [.clear, .clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
            Text(displayName)
                .font(.system(size: 24, weight: .black))
                .foregroundStyle(.white)
                .padding(18)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            if active {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.cyan, lineWidth: 5)
                    .shadow(color: .cyan.opacity(0.9), radius: 14)
            }
        }
        .overlay(alignment: .topTrailing) {
            if active {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text("MOTION")
                }
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.cyan, in: Capsule())
                .padding(14)
            }
        }
        .scaleEffect(active ? 1.03 : 1)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: active)
    }
}

/// AVPlayerLayer-backed live HLS view for tvOS.
private struct TVPlayerView: UIViewRepresentable {
    let url: URL
    let makeItem: (URL) -> AVPlayerItem

    func makeUIView(context: Context) -> TVPlayerLayerView {
        let view = TVPlayerLayerView()
        let player = AVPlayer(playerItem: makeItem(url))
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        player.play()
        return view
    }

    func updateUIView(_ view: TVPlayerLayerView, context: Context) {}

    static func dismantleUIView(_ view: TVPlayerLayerView, coordinator: ()) {
        view.playerLayer.player?.pause()
        view.playerLayer.player = nil
    }
}

private final class TVPlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
