import AVKit
import SwiftUI

/// The big-screen command center: a live wall of every camera with AI Smart Focus,
/// plus a full-screen Patrol mode that auto-cycles through cameras and jumps to whatever
/// just detected motion. Play/Pause on the Siri Remote flips 2-up / 3-up; the Patrol
/// button starts the cycle; the Menu button exits Patrol.
struct TVWallView: View {
    @EnvironmentObject private var state: TVAppState
    @State private var columns = 2
    @State private var patrol = false

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
            } else if patrol {
                TVPatrolView(onExit: { withAnimation { patrol = false } })
            } else {
                VStack(spacing: 0) {
                    controlBar
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
        }
        .onPlayPauseCommand { if !patrol { columns = (columns == 2) ? 3 : 2 } }
    }

    private var controlBar: some View {
        HStack(spacing: 20) {
            Button { withAnimation { patrol = true } } label: {
                Label("Patrol", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 22, weight: .black))
            }
            Spacer()
            Text("\(state.cameras.count) cameras")
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 50)
        .padding(.top, 40)
        .padding(.bottom, 10)
    }
}

// MARK: - Patrol (auto-cycle + jump to motion)

private struct TVPatrolView: View {
    @EnvironmentObject private var state: TVAppState
    var onExit: () -> Void

    @State private var index = 0
    private let interval: Double = 10

    private var isDetection: Bool { state.activeCamera != nil }

    /// Detection wins; otherwise the rotating patrol camera.
    private var shown: FrigateCamera? {
        if let active = state.activeCamera,
           let cam = state.cameras.first(where: { $0.name == active }) {
            return cam
        }
        guard !state.cameras.isEmpty else { return nil }
        return state.cameras[index % state.cameras.count]
    }

    private var position: String {
        guard let shown, let i = state.cameras.firstIndex(where: { $0.id == shown.id }) else { return "" }
        return "\(i + 1) / \(state.cameras.count)"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let cam = shown, let client = state.client {
                TVPlayerView(url: client.liveHLSURL(camera: cam.name)) { client.playerItem(for: $0) }
                    .id(cam.name)
                    .transition(.opacity)
                    .ignoresSafeArea()

                VStack {
                    HStack {
                        Label(isDetection ? "MOTION" : "PATROL",
                              systemImage: isDetection ? "sparkles" : "arrow.triangle.2.circlepath")
                            .font(.system(size: 22, weight: .black))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(.cyan, in: Capsule())
                        Spacer()
                        Text(position)
                            .font(.system(size: 22, weight: .black))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    Spacer()
                    HStack {
                        Text(cam.name.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.system(size: 44, weight: .black))
                            .foregroundStyle(.white)
                            .shadow(radius: 8)
                        Spacer()
                    }
                }
                .padding(60)
            }
        }
        .overlay {
            if isDetection {
                Rectangle().strokeBorder(.cyan, lineWidth: 8).ignoresSafeArea()
            }
        }
        .animation(.easeInOut(duration: 0.5), value: shown?.name)
        .animation(.easeInOut(duration: 0.3), value: isDetection)
        .focusable()
        .onExitCommand { onExit() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                // Don't advance while a detection is on screen — let motion linger.
                if state.activeCamera == nil, !state.cameras.isEmpty {
                    withAnimation(.easeInOut(duration: 0.5)) {
                        index = (index + 1) % state.cameras.count
                    }
                }
            }
        }
    }
}

// MARK: - Wall tile

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
