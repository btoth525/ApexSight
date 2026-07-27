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
                } else if value == "house" {
                    HouseModeView()
                        .environmentObject(appState)
                }
            }
        }
    }

    // MARK: - Live wall (normal mode)

    /// Lazy stack: only tiles near the viewport instantiate, so an off-screen camera's snapshot
    /// refresh loop (a `latest.jpg` fetch + downsample every ~3s) doesn't keep running for every
    /// camera on the wall — that was continuous wasted network/CPU/battery for the ~6-7 cameras
    /// scrolled out of view. SwiftUI keeps a buffer of just-off-screen tiles alive, and each tile
    /// paints its cached last frame immediately on reappear, so scrolling back shows the frame with
    /// at most a fresh fetch, not a flicker. Tiles are snapshot-based (CameraCard → LiveSnapshotView),
    /// not persistent HLS, so nothing live is being torn down here.
    /// NOTE: this is a behavior change to the wall's scroll/keep-warm model — compiler-verified only;
    /// confirm the scroll-back feel against real Frigate on device (this sim has no credentials).
    private var liveScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if !isEditing {
                    HouseModeSwitcher(onOpenDetail: { path.append("house") })
                    householdSnoozeBanner
                    focusMuteBanner
                }

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
                    // Index-keyed rows: the row container is reused and the inner ForEach diffs
                    // tiles by camera.id, so unchanged tiles in a row are reused. (Content-keying
                    // the row rebuilds the whole HStack — including unchanged tiles — on any change.)
                    // iPad/regular-width only.
                    ForEach(Array(cameraRows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: GlassTheme.Space.m) {
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
            .padding(GlassTheme.Space.l)
        }
        .softScrollEdges()
        .refreshable { await appState.refresh() }
        .task {
            if appState.cameras.isEmpty { await appState.refresh() }
            // Warm snapshots so every tile shows a frame instantly (never black).
            else { appState.prewarmSnapshots() }
            // Populate the House Mode bar promptly (the 15s poll refreshes it thereafter).
            await appState.refreshHouseMode()
        }
    }

    /// A few tile-shaped shimmer placeholders so the first load reads as "filling in," not
    /// a blank screen or a centered spinner.
    private var loadingSkeleton: some View {
        VStack(spacing: GlassTheme.Space.m) {
            ForEach(0..<4, id: \.self) { _ in
                SkeletonBlock(cornerRadius: GlassTheme.Radius.tile)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    /// Loud home-screen banner when the HOUSEHOLD notification gate is silencing every push —
    /// a snooze/disarm can come from Siri, a widget, or a partner's phone, and without this it
    /// was invisible ("why am I not getting notifications?"). One tap resumes for everyone.
    @ViewBuilder
    private var householdSnoozeBanner: some View {
        if appState.householdDisarmed || appState.householdSnoozedUntil > Date().timeIntervalSince1970 {
            Button {
                Haptics.tap()
                Task { await appState.resumeHouseholdNotifications() }
            } label: {
                HStack(spacing: GlassTheme.Space.m) {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(GlassTheme.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(appState.householdDisarmed
                             ? "Notifications OFF for everyone"
                             : "Notifications snoozed until \(Date(timeIntervalSince1970: appState.householdSnoozedUntil).formatted(date: .omitted, time: .shortened))")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(GlassTheme.primary)
                        Text(appState.householdGateAttribution.map { "\($0) · Tap to resume" }
                             ?? "Tap to resume alerts")
                            .font(.caption2)
                            .foregroundStyle(GlassTheme.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title3)
                        .foregroundStyle(GlassTheme.orange)
                }
                .padding(.horizontal, GlassTheme.Space.l)
                .padding(.vertical, GlassTheme.Space.m)
                .background(GlassTheme.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: GlassTheme.Radius.tile))
                .overlay(RoundedRectangle(cornerRadius: GlassTheme.Radius.tile)
                    .stroke(GlassTheme.orange.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    /// Quieter sibling of the household banner: THIS phone's alerts are paused by one of its own
    /// iOS Focuses. Deliberately not a "resume" button — the fix is turning the Focus off (or
    /// removing ApexSight from its Focus Filters), and a button that fought the Focus would just
    /// be overridden the next time it activated. This exists so the phone is never silently quiet:
    /// the household version of this mute was invisible, which is exactly what made it hard to
    /// diagnose. Informational only, so it doesn't shout like the household banner.
    @ViewBuilder
    private var focusMuteBanner: some View {
        if !appState.householdDisarmed,
           appState.householdSnoozedUntil <= Date().timeIntervalSince1970,
           appState.focusMutedUntil > Date().timeIntervalSince1970 {
            let until = Date(timeIntervalSince1970: appState.focusMutedUntil)
            HStack(spacing: GlassTheme.Space.s) {
                Image(systemName: "moon.fill")
                    // Dynamic Type-relative, not a fixed pixel size, so the glyph grows with the
                    // label instead of shrinking away from it at large text sizes.
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(GlassTheme.primary)
                // This tells the user why their alerts are silent, so it's security-relevant and
                // must not sit at the lowest contrast tier — the same finding an earlier audit
                // raised against HouseModeView's who-armed text. .footnote (scales) + .primary.
                Text("Alerts paused on this iPhone by a Focus · until \(until.formatted(date: .omitted, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(GlassTheme.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, GlassTheme.Space.l)
            .padding(.vertical, GlassTheme.Space.s)
            .background(GlassTheme.surface, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.chip))
            .accessibilityElement(children: .combine)
        }
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
        return HStack(spacing: GlassTheme.Space.m) {
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

