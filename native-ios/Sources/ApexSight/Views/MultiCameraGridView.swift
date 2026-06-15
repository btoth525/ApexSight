import AVFoundation
import SwiftUI

struct MultiCameraGridView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    /// Number of columns: 1, 2 (default), or 3
    @State private var columns = 2
    @State private var players: [String: AVPlayer] = [:]
    @State private var selectedCamera: FrigateCamera?

    private var displayedCameras: [FrigateCamera] {
        appState.cameras
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if displayedCameras.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .navigationTitle("Multi-View")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20, weight: .black))
                            .foregroundStyle(GlassTheme.secondary)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    columnPicker
                }
            }
            .toolbarBackground(.black.opacity(0.8), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task { await startAllStreams() }
            .onDisappear { pauseAll() }
            .sheet(item: $selectedCamera) { camera in
                NavigationStack {
                    LiveStreamView(camera: camera)
                }
                .preferredColorScheme(.dark)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns),
                spacing: 2
            ) {
                ForEach(displayedCameras) { camera in
                    cameraCell(camera)
                }
            }
        }
    }

    private func cameraCell(_ camera: FrigateCamera) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let player = players[camera.name] {
                GridPlayerCell(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(Color.black)
            } else {
                // placeholder while stream loads
                ZStack {
                    Color.black.aspectRatio(16 / 9, contentMode: .fit)
                    ProgressView().tint(GlassTheme.cyan)
                }
            }

            // camera name pill
            Text(titleize(camera.name))
                .font(.system(size: columns > 2 ? 9 : 11, weight: .black))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(6)
        }
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { selectedCamera = camera }
    }

    // MARK: - Column picker

    private var columnPicker: some View {
        Menu {
            ForEach([1, 2, 3], id: \.self) { n in
                Button {
                    columns = n
                } label: {
                    Label(
                        n == 1 ? "Single" : "\(n)×\(n) Grid",
                        systemImage: n == 1 ? "rectangle" : (n == 2 ? "rectangle.grid.2x2" : "rectangle.grid.3x2")
                    )
                }
            }
        } label: {
            Image(systemName: layoutIcon)
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(GlassTheme.cyan)
        }
    }

    private var layoutIcon: String {
        switch columns {
        case 1:  return "rectangle"
        case 3:  return "rectangle.grid.3x2"
        default: return "rectangle.grid.2x2"
        }
    }

    // MARK: - Stream management

    private func startAllStreams() async {
        guard let client = appState.client else { return }

        for camera in displayedCameras {
            guard players[camera.name] == nil else { continue }

            let url = client.liveHLSURL(camera: camera.name)
            let item = client.playerItem(for: url)
            item.preferredForwardBufferDuration = 2     // keep buffer small in grid
            let player = AVPlayer(playerItem: item)
            player.isMuted = true           // muted in grid; unmuted in full-screen LiveStreamView
            player.play()
            players[camera.name] = player
        }
    }

    private func pauseAll() {
        players.values.forEach { $0.pause() }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 48, weight: .black))
                .foregroundStyle(GlassTheme.secondary)
            Text("No Cameras")
                .font(.system(size: 22, weight: .black))
                .foregroundStyle(GlassTheme.primary)
            Text("Connect a Frigate server in Settings to see live feeds.")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(GlassTheme.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}
