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
                    VStack(alignment: .leading, spacing: 16) {
                        // Status strip
                        statusStrip

                        groupsStrip

                        if let error = appState.errorMessage {
                            GlassCard {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.system(size: 14, weight: .heavy))
                                    .foregroundStyle(GlassTheme.orange)
                            }
                        }

                        GlassCard {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Live Cameras")
                                            .font(.system(size: 21, weight: .black))
                                            .foregroundStyle(GlassTheme.primary)
                                        Text("\(appState.cameras.count) online")
                                            .font(.system(size: 12, weight: .heavy))
                                            .foregroundStyle(GlassTheme.secondary)
                                    }
                                    Spacer()
                                    if appState.isLoading {
                                        ProgressView().tint(GlassTheme.cyan)
                                    }
                                }
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                                    ForEach(appState.cameras) { camera in
                                        CameraCard(camera: camera)
                                    }
                                }
                            }
                        }

                        if !appState.capabilities.isEmpty {
                            GlassCard {
                                VStack(alignment: .leading, spacing: 14) {
                                    Text("Camera Capabilities")
                                        .font(.system(size: 21, weight: .black))
                                        .foregroundStyle(GlassTheme.primary)
                                    VStack(spacing: 10) {
                                        ForEach(appState.capabilities) { cap in
                                            CapabilityRow(capability: cap)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                .refreshable { await appState.refresh() }
                .task { if appState.cameras.isEmpty { await appState.refresh() } }
            }
            .navigationTitle("Apex Command")
            .navigationBarTitleDisplayMode(.inline)
            .glassNavBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 10) {
                        Button {
                            liveWall = .all
                        } label: {
                            Image(systemName: "rectangle.grid.2x2.fill")
                                .font(.system(size: 16, weight: .black))
                                .foregroundStyle(GlassTheme.cyan)
                        }
                        if let host = appState.session?.baseURL.host() {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(appState.isLive ? GlassTheme.green : GlassTheme.tertiary)
                                    .frame(width: 7, height: 7)
                                Text(host)
                                    .font(.system(size: 11, weight: .heavy))
                                    .foregroundStyle(GlassTheme.cyan)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(GlassTheme.cyan.opacity(0.15), in: Capsule())
                        }
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

    private var groupsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(groupStore.groups) { group in
                    Button { liveWall = .group(group) } label: {
                        groupChip(icon: "square.grid.2x2.fill", title: group.name, subtitle: "\(group.cameraNames.count) cams", tint: GlassTheme.cyan)
                    }
                    .buttonStyle(.plain)
                }
                Button { path.append("groups") } label: {
                    groupChip(icon: "plus", title: "Groups", subtitle: "Manage", tint: GlassTheme.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func groupChip(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(GlassTheme.primary)
                    .lineLimit(1)
                Text(subtitle.uppercased())
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(GlassTheme.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var statusStrip: some View {
        HStack(spacing: 8) {
            statusMetric(icon: "video.fill", title: "Live", value: "\(appState.cameras.count)", tint: GlassTheme.blue)
            statusMetric(icon: "bell.badge.fill", title: "Review", value: "\(appState.reviews.count)", tint: GlassTheme.orange)
            statusMetric(icon: "tag.fill", title: "Labels", value: "\(appState.labels.count)", tint: GlassTheme.cyan)
            statusMetric(icon: "waveform.path.ecg", title: "Health",
                         value: appState.errorMessage == nil ? "Good" : "Check",
                         tint: appState.errorMessage == nil ? GlassTheme.green : GlassTheme.red)
        }
    }

    private func statusMetric(icon: String, title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(tint)
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(GlassTheme.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 17, weight: .black))
                .foregroundStyle(GlassTheme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
