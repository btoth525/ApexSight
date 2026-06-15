import SwiftUI

struct CamerasTab: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var groupStore = CameraGroupStore()
    @State private var liveWall: LiveWallTarget?
    @State private var path = NavigationPath()

    private enum LiveWallTarget: Identifiable {
        case all
        case group(CameraGroup)
        var id: String {
            switch self {
            case .all: return "all"
            case .group(let g): return g.id.uuidString
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                GlassBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let error = appState.errorMessage {
                            GlassCard {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.system(size: 14, weight: .heavy))
                                    .foregroundStyle(GlassTheme.orange)
                            }
                        }

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                            ForEach(appState.cameras) { camera in
                                CameraCard(camera: camera)
                            }
                        }

                        if appState.cameras.isEmpty && !appState.isLoading {
                            emptyState
                        }
                    }
                    .padding(16)
                }
                .refreshable { await appState.refresh() }
                .task { if appState.cameras.isEmpty { await appState.refresh() } }
            }
            .navigationTitle("Cameras")
            .navigationBarTitleDisplayMode(.inline)
            .glassNavBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 14) {
                        if appState.isLoading {
                            ProgressView().tint(GlassTheme.cyan)
                        }
                        multiViewMenu
                    }
                }
            }
            .fullScreenCover(item: $liveWall) { target in
                switch target {
                case .all:
                    MultiCameraGridView()
                        .environmentObject(appState)
                case .group(let group):
                    MultiCameraGridView(group: group)
                        .environmentObject(appState)
                }
            }
            .navigationDestination(for: String.self) { value in
                if value == "groups" {
                    CameraGroupsView(store: groupStore)
                        .environmentObject(appState)
                }
            }
        }
    }

    private var multiViewMenu: some View {
        Menu {
            Button {
                liveWall = .all
            } label: {
                Label("All Cameras Wall", systemImage: "rectangle.grid.2x2.fill")
            }
            if !groupStore.groups.isEmpty {
                Section("Saved Grids") {
                    ForEach(groupStore.groups) { group in
                        Button {
                            liveWall = .group(group)
                        } label: {
                            Label("\(group.name) (\(group.cameraNames.count))", systemImage: "square.grid.2x2")
                        }
                    }
                }
            }
            Divider()
            Button {
                path.append("groups")
            } label: {
                Label("Manage Grids", systemImage: "slider.horizontal.3")
            }
        } label: {
            Image(systemName: "rectangle.grid.2x2.fill")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(GlassTheme.cyan)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 44, weight: .black))
                .foregroundStyle(GlassTheme.secondary)
            Text("No Cameras")
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(GlassTheme.primary)
            Text("Pull to refresh, or check your Frigate connection in Settings.")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(GlassTheme.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}
