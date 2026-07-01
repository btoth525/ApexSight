import SwiftUI
import UniformTypeIdentifiers

struct CamerasTab: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var groupStore = CameraGroupStore()
    @StateObject private var layout = CameraLayoutStore()
    @State private var liveWall: LiveWallTarget?
    @State private var showBirdseye = false
    @State private var path = NavigationPath()

    // Edit / arrange mode
    @State private var isEditing = false
    @State private var draft: [FrigateCamera] = []
    @State private var draftHidden: Set<String> = []

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
                    editList
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
            .fullScreenCover(isPresented: $showBirdseye) {
                NavigationStack {
                    LiveStreamView(camera: FrigateCamera(name: "birdseye", zones: [], objects: []))
                        .environmentObject(appState)
                }
                .preferredColorScheme(.dark)
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
                    errorCard(error)
                }

                if appState.cameras.isEmpty {
                    if appState.isLoading {
                        // Tile-shaped skeleton (not a lone spinner) so the wall shows its
                        // shape immediately while the first fetch is in flight.
                        loadingSkeleton
                    } else if appState.errorMessage == nil {
                        emptyState
                    }
                } else if columns == 1 {
                    // Flat, per-camera identity (not row-index) so reordering / hiding a camera
                    // shifts the others WITHOUT tearing down and reconnecting their persistent
                    // HLS players — keeping the wall live with no black flash.
                    ForEach(visibleCameras) { camera in
                        CameraCard(camera: camera)
                            .frame(maxWidth: .infinity)
                    }
                } else {
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
                }
            }
            .padding(16)
        }
        .softScrollEdges()
        .refreshable { await appState.refresh() }
        .task {
            if appState.cameras.isEmpty { await appState.refresh() }
            // Warm snapshots so every tile shows a frame instantly (never black).
            else { appState.prewarmSnapshots() }
        }
    }

    /// A few tile-shaped shimmer placeholders so the first load reads as "filling in," not
    /// a blank screen or a centered spinner.
    private var loadingSkeleton: some View {
        VStack(spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                SkeletonBlock(cornerRadius: GlassTheme.Radius.tile)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    /// A calm error+retry card — the fetch failed but the user can recover in place.
    private func errorCard(_ message: String) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(GlassTheme.orange)
                Button {
                    Haptics.tap()
                    Task { await appState.refresh() }
                } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PillButtonStyle())
                .accessibilityLabel("Retry loading cameras")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cameraRows: [[FrigateCamera]] {
        let cams = visibleCameras
        return stride(from: 0, to: cams.count, by: columns).map { start in
            Array(cams[start..<min(start + columns, cams.count)])
        }
    }

    // MARK: - Arrange / reorder mode

    // A List with .onMove gives rock-solid, oscillation-free reordering (the system owns the
    // index math and drag handles), unlike the hand-rolled LazyVGrid DropDelegate it replaces.
    private var editList: some View {
        List {
            Section {
                ForEach(draft) { camera in
                    editRow(camera)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                }
                .onMove { from, to in
                    Haptics.tap()
                    draft.move(fromOffsets: from, toOffset: to)
                }
            } header: {
                Text("Drag the handle to reorder · tap a camera to show or hide it on your wall.")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(GlassTheme.secondary)
                    .textCase(nil)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // editMode active so List shows the reorder handles and enables .onMove immediately.
        .environment(\.editMode, .constant(.active))
    }

    private func editRow(_ camera: FrigateCamera) -> some View {
        let isHidden = draftHidden.contains(camera.name)
        return HStack(spacing: 12) {
            ZStack {
                if let url = appState.client?.latestFrameURL(camera: camera.name) {
                    RemoteImage(url: url, contentMode: .fill)
                } else {
                    Color.black
                }
            }
            .frame(width: 92, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isHidden ? GlassTheme.secondary.opacity(0.4) : GlassTheme.cyan.opacity(0.5), lineWidth: 1)
            }
            .opacity(isHidden ? 0.4 : 1)

            Text(titleize(camera.name))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(isHidden ? GlassTheme.secondary : GlassTheme.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            // Explicit show/hide toggle — reliable in edit mode (row taps are reserved for drag).
            Button {
                Haptics.select()
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                    if draftHidden.contains(camera.name) { draftHidden.remove(camera.name) }
                    else { draftHidden.insert(camera.name) }
                }
            } label: {
                Image(systemName: isHidden ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(isHidden ? GlassTheme.secondary : GlassTheme.green)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isHidden ? "Show \(titleize(camera.name)) on wall" : "Hide \(titleize(camera.name)) from wall")
        }
        .accessibilityElement(children: .combine)
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
                        Button {
                            Haptics.tap()
                            beginEditing()
                        } label: {
                            Image(systemName: "arrow.up.arrow.down.circle")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(GlassTheme.cyan)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
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
    }

    private func cancelEditing() {
        Haptics.tap()
        withAnimation { isEditing = false }
    }

    private func commitEditing() {
        Haptics.select()
        layout.commit(order: draft.map(\.name), hidden: draftHidden)
        withAnimation { isEditing = false }
    }

    private var multiViewMenu: some View {
        Menu {
            if appState.hasBirdseye {
                Button {
                    Haptics.tap()
                    showBirdseye = true
                } label: {
                    Label("Birdseye View", systemImage: "squareshape.split.2x2")
                }
            }
            Button {
                Haptics.select()
                liveWall = .all
            } label: {
                Label("All Cameras Wall", systemImage: "rectangle.grid.2x2.fill")
            }
            if !groupStore.groups.isEmpty {
                Section("Saved Grids") {
                    ForEach(groupStore.groups) { group in
                        Button {
                            Haptics.select()
                            liveWall = .group(group)
                        } label: {
                            Label("\(group.name) (\(group.cameraNames.count))", systemImage: "square.grid.2x2")
                        }
                    }
                }
            }
            Divider()
            Button {
                Haptics.tap()
                path.append("groups")
            } label: {
                Label("Manage Grids", systemImage: "slider.horizontal.3")
            }
        } label: {
            Image(systemName: "rectangle.grid.2x2.fill")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(GlassTheme.cyan)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Multi-camera views")
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: "video.slash.fill",
            title: "No Cameras",
            message: "Pull to refresh, or check your Frigate connection in Settings."
        )
        .padding(.top, 60)
    }
}

