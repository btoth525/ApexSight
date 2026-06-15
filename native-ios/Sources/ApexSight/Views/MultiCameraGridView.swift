import SwiftUI

struct MultiCameraGridView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let group: CameraGroup?

    /// Number of columns: 1, 2 (default), or 3
    @State private var columns: Int
    @State private var selectedCamera: FrigateCamera?

    init(group: CameraGroup? = nil) {
        self.group = group
        _columns = State(initialValue: group?.columns ?? 2)
    }

    private var displayedCameras: [FrigateCamera] {
        guard let group else { return appState.cameras }
        let order = group.cameraNames
        return appState.cameras
            .filter { order.contains($0.name) }
            .sorted { (order.firstIndex(of: $0.name) ?? 0) < (order.firstIndex(of: $1.name) ?? 0) }
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
            .navigationTitle(group?.name ?? "Multi-View")
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
            Color.black
            // HLSLivePlayerView shows its own snapshot placeholder internally.
            HLSLivePlayerView(camera: camera)
                .allowsHitTesting(false)

            // camera name pill
            Text(titleize(camera.name))
                .font(.system(size: columns > 2 ? 9 : 11, weight: .black))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(6)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { selectedCamera = camera }
    }

    // MARK: - Column picker

    private var columnPicker: some View {
        Menu {
            ForEach([1, 2, 3, 4], id: \.self) { n in
                Button {
                    columns = n
                } label: {
                    Label(
                        n == 1 ? "Single" : "\(n)-up Wall",
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
