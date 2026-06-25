import SwiftUI
import UniformTypeIdentifiers

struct CamerasTab: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var groupStore = CameraGroupStore()
    @StateObject private var layout = CameraLayoutStore()
    @State private var liveWall: LiveWallTarget?
    @State private var path = NavigationPath()

    // Edit / arrange mode
    @State private var isEditing = false
    @State private var draft: [FrigateCamera] = []
    @State private var draftHidden: Set<String> = []
    @State private var dragging: FrigateCamera?
    @State private var wobble = false

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

    /// One camera per row on iPhone (big feeds), two-up on iPad/regular width.
    private var columns: Int { horizontalSizeClass == .regular ? 2 : 1 }

    private var visibleCameras: [FrigateCamera] { layout.visible(appState.cameras) }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                GlassBackground()
                if isEditing {
                    editGrid
                } else {
                    liveScroll
                }
            }
            .navigationTitle(isEditing ? "Arrange Cameras" : "Cameras")
            .navigationBarTitleDisplayMode(.inline)
            .glassNavBar()
            .toolbar { toolbarContent }
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

    // MARK: - Live wall (normal mode)

    /// A plain (non-lazy) stack so every camera's feed loads and STAYS live as you
    /// scroll, instead of flickering on/off as cells recycle. Feeds are persistent: they
    /// keep streaming across tab switches and only drop the connection while the app is
    /// backgrounded (rebuilding instantly on return).
    private var liveScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error = appState.errorMessage {
                    GlassCard {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(GlassTheme.orange)
                    }
                }

                ForEach(Array(cameraRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 12) {
                        ForEach(row) { camera in
                            CameraCard(camera: camera)
                                .frame(maxWidth: .infinity)
                        }
                        if row.count < columns {
                            ForEach(0..<(columns - row.count), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }

                if appState.cameras.isEmpty && !appState.isLoading {
                    emptyState
                }
            }
            .padding(16)
        }
        .refreshable { await appState.refresh() }
        .task {
            if appState.cameras.isEmpty { await appState.refresh() }
            // Warm snapshots so every tile shows a frame instantly (never black).
            else { appState.prewarmSnapshots() }
        }
    }

    private var cameraRows: [[FrigateCamera]] {
        let cams = visibleCameras
        return stride(from: 0, to: cams.count, by: columns).map { start in
            Array(cams[start..<min(start + columns, cams.count)])
        }
    }

    // MARK: - Arrange / reorder mode

    private var editGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Drag to reorder · tap a camera to show or hide it on your wall.")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(GlassTheme.secondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)

                LazyVGrid(columns: editColumns, spacing: 12) {
                    ForEach(draft) { camera in
                        editTile(camera)
                            .onDrag {
                                dragging = camera
                                return NSItemProvider(object: camera.name as NSString)
                            }
                            .onDrop(
                                of: [.text],
                                delegate: CameraReorderDropDelegate(item: camera, draft: $draft, dragging: $dragging)
                            )
                    }
                }
            }
            .padding(16)
        }
    }

    private var editColumns: [GridItem] {
        let n = horizontalSizeClass == .regular ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: n)
    }

    private func editTile(_ camera: FrigateCamera) -> some View {
        let isHidden = draftHidden.contains(camera.name)
        return ZStack(alignment: .topTrailing) {
            ZStack(alignment: .bottomLeading) {
                if let url = appState.client?.latestFrameURL(camera: camera.name) {
                    RemoteImage(url: url, contentMode: .fill)
                } else {
                    Color.black
                }

                Text(titleize(camera.name))
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(6)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(isHidden ? 0.35 : 1)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isHidden ? GlassTheme.secondary.opacity(0.4) : GlassTheme.cyan.opacity(0.5), lineWidth: 1.5)
            }

            Image(systemName: isHidden ? "circle" : "checkmark.circle.fill")
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(isHidden ? Color.white.opacity(0.75) : GlassTheme.green)
                .background { Circle().fill(.black.opacity(0.55)) }
                .padding(6)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                if draftHidden.contains(camera.name) { draftHidden.remove(camera.name) }
                else { draftHidden.insert(camera.name) }
            }
        }
        .rotationEffect(.degrees(wobble ? wobbleAmount(for: camera) : -wobbleAmount(for: camera)))
        .animation(
            .easeInOut(duration: wobbleDuration(for: camera)).repeatForever(autoreverses: true),
            value: wobble
        )
    }

    /// A small per-camera wobble so arrange mode reads like the iOS Home Screen jiggle,
    /// slightly desynced per tile so they don't all move in lockstep.
    private func wobbleAmount(for camera: FrigateCamera) -> Double {
        // Mask the sign bit instead of abs() — abs(Int.min) would trap.
        1.0 + Double((camera.name.hashValue & Int.max) % 6) * 0.08   // 1.0°…~1.4°
    }

    private func wobbleDuration(for camera: FrigateCamera) -> Double {
        0.15 + Double((camera.name.hashValue & Int.max) % 5) * 0.012  // 0.15s…~0.20s
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isEditing {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel") { cancelEditing() }
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(GlassTheme.secondary)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { commitEditing() }
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(GlassTheme.cyan)
            }
        } else {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    if appState.isLoading {
                        ProgressView().tint(GlassTheme.cyan)
                    }
                    if appState.cameras.count > 1 {
                        Button { beginEditing() } label: {
                            Image(systemName: "arrow.up.arrow.down.circle")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(GlassTheme.cyan)
                        }
                        .accessibilityLabel("Arrange cameras")
                    }
                    multiViewMenu
                }
            }
        }
    }

    private func beginEditing() {
        draft = layout.arranged(appState.cameras)
        draftHidden = layout.hidden
        withAnimation { isEditing = true }
        wobble = true
    }

    private func cancelEditing() {
        wobble = false
        withAnimation { isEditing = false }
    }

    private func commitEditing() {
        layout.commit(order: draft.map(\.name), hidden: draftHidden)
        wobble = false
        withAnimation { isEditing = false }
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
        .accessibilityLabel("Multi-camera views")
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

// MARK: - Drag-to-reorder

private struct CameraReorderDropDelegate: DropDelegate {
    let item: FrigateCamera
    @Binding var draft: [FrigateCamera]
    @Binding var dragging: FrigateCamera?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item,
              let from = draft.firstIndex(of: dragging),
              let to = draft.firstIndex(of: item)
        else { return }
        if draft[to] != dragging {
            withAnimation {
                draft.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
