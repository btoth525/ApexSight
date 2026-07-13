import SwiftUI
import UIKit

struct MultiCameraGridView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let group: CameraGroup?

    /// Number of columns: 1, 2 (default), or 3
    @State private var columns: Int
    @State private var selectedCamera: FrigateCamera?
    @State private var showBirdseye = false
    // Smart Focus: spotlight + scroll to the camera where Frigate just detected something.
    @AppStorage("multiview.smartFocus") private var smartFocus = true
    @State private var activeCameraName: String?
    @State private var lastEventID: String?
    @State private var clearWork: Task<Void, Never>?

    init(group: CameraGroup? = nil) {
        self.group = group
        // Default to one camera per row on iPhone (big, easy to read) and two-up on iPad.
        let deviceDefault = UIDevice.current.userInterfaceIdiom == .pad ? 2 : 1
        _columns = State(initialValue: group?.columns ?? deviceDefault)
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
                    Button {
                        Haptics.tap()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(GlassTheme.primary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Close wall")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: GlassTheme.Space.l) {
                        if appState.hasBirdseye {
                            Button {
                                Haptics.tap()
                                showBirdseye = true
                            } label: {
                                Image(systemName: "squareshape.split.2x2")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(GlassTheme.accent)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Birdseye view")
                        }
                        Button {
                            Haptics.select()
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { smartFocus.toggle() }
                            if !smartFocus { activeCameraName = nil }
                        } label: {
                            Image(systemName: "sparkles")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(smartFocus ? GlassTheme.accent : GlassTheme.tertiary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(smartFocus ? "Smart Focus on" : "Smart Focus off")
                        columnPicker
                    }
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            // iOS 27: collapse the nav bar while scrolling the wall so the feeds get full height.
            .ios27ToolbarMinimizeOnScroll()
            .sheet(item: $selectedCamera) { camera in
                NavigationStack {
                    LiveStreamView(camera: camera)
                }
                .environmentObject(appState)
                .preferredColorScheme(.dark)
            }
            .sheet(isPresented: $showBirdseye) {
                NavigationStack {
                    LiveStreamView(camera: FrigateCamera(name: "birdseye", zones: [], objects: []))
                }
                .environmentObject(appState)
                .preferredColorScheme(.dark)
            }
            // Cancel the pending spotlight-clear so it can't mutate state after the wall closes.
            .onDisappear { clearWork?.cancel(); clearWork = nil }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy so rows scrolled off the wall stop decoding video.
                LazyVStack(spacing: 2) {
                    ForEach(cameraRows, id: \.self) { rowIndices in
                        HStack(spacing: 2) {
                            ForEach(rowIndices, id: \.self) { idx in
                                MultiCameraCell(
                                    camera: displayedCameras[idx],
                                    columns: columns,
                                    active: displayedCameras[idx].name == activeCameraName,
                                    onTap: { selectedCamera = displayedCameras[idx] }
                                )
                                .id(displayedCameras[idx].name)
                            }
                            // Fill partial last row
                            if rowIndices.count < columns {
                                ForEach(0..<(columns - rowIndices.count), id: \.self) { _ in
                                    Color.black.aspectRatio(16.0/9.0, contentMode: .fit)
                                }
                            }
                        }
                    }
                }
            }
            // Smart Focus: glide to whichever camera just lit up (jump instantly under Reduce Motion).
            .onChange(of: activeCameraName) { _, name in
                guard let name else { return }
                if reduceMotion {
                    proxy.scrollTo(name, anchor: .center)
                } else {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                        proxy.scrollTo(name, anchor: .center)
                    }
                }
            }
        }
        // Detect the newest event and spotlight its camera if it's on this wall.
        .onChange(of: appState.events.first?.id) { _, newID in
            guard smartFocus, let newID, newID != lastEventID else { return }
            lastEventID = newID
            if let cam = appState.events.first?.camera,
               displayedCameras.contains(where: { $0.name == cam }) {
                spotlight(cam)
            }
        }
        .task {
            // Don't fire on the existing backlog — only genuinely new events after open.
            lastEventID = appState.events.first?.id
            // Warm snapshots for ALL tiles up front so scrolling never reveals a black cell.
            appState.prewarmSnapshots()
        }
    }

    private func spotlight(_ name: String) {
        clearWork?.cancel()
        Haptics.tap()
        withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.8)) { activeCameraName = name }
        clearWork = Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
                if activeCameraName == name { activeCameraName = nil }
            }
        }
    }

    private var cameraRows: [[Int]] {
        let count = displayedCameras.count
        // max(1,...) so a corrupted/legacy persisted group with columns == 0 can't trap
        // stride (stride(by: 0) is a fatal precondition).
        let step = max(1, columns)
        return stride(from: 0, to: count, by: step).map { start in
            Array(start..<min(start + step, count))
        }
    }

    // MARK: - Column picker

    private var columnPicker: some View {
        Menu {
            ForEach([1, 2, 3, 4], id: \.self) { n in
                Button {
                    guard columns != n else { return }
                    Haptics.select()
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { columns = n }
                } label: {
                    // A checkmark marks the active layout so the picker reads as a real selector.
                    Label(
                        n == 1 ? "Single" : "\(n)-up Wall",
                        systemImage: columns == n
                            ? "checkmark"
                            : (n == 1 ? "rectangle" : (n == 2 ? "rectangle.grid.2x2" : "rectangle.grid.3x2"))
                    )
                }
            }
        } label: {
            Image(systemName: layoutIcon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(GlassTheme.accent)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Wall layout")
        .accessibilityValue(columns == 1 ? "Single" : "\(columns) up")
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
        EmptyStateView(
            icon: "video.slash.fill",
            title: "No Cameras",
            message: "Connect a Frigate server in Settings to see live feeds."
        )
    }
}

// MARK: - Wall cell

/// One tile on the multi-camera wall. Owns its own "is it live yet" state so it can show a
/// calm connecting hint over the cached snapshot until the first frame arrives — the wall
/// never reads as a grid of frozen or dead-black panels.
private struct MultiCameraCell: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let camera: FrigateCamera
    let columns: Int
    let active: Bool
    let onTap: () -> Void

    @State private var isLive = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            // Auto-refreshing snapshot (current frame every few seconds) rather than many
            // simultaneous live streams — a dense grid of live WebRTC feeds spins up slowly and
            // stampedes the server. Tapping a tile opens that camera full-quality LIVE. Matches
            // the main wall (CameraCard) and the Ring/Nest/UniFi grid model.
            LiveSnapshotView(
                camera: camera,
                onFrame: { hasFrame in
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { isLive = hasFrame }
                }
            )
            .allowsHitTesting(false)

            // Calm "warming up" hint over the snapshot until the tile goes live.
            if !isLive {
                ConnectingHint()
                    .transition(.opacity)
            }

            // Bottom scrim so the name stays legible over bright scenes (matches CameraCard).
            LinearGradient(
                colors: [.clear, .clear, .black.opacity(0.7)],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)

            // Camera name — consistent with CameraCard's bottom-leading title.
            Text(titleize(camera.name))
                .font(.system(size: columns > 2 ? 11 : 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
                .padding(.horizontal, GlassTheme.Space.s)
                .padding(.vertical, GlassTheme.Space.xs)
        }
        .aspectRatio(camera.aspectRatio, contentMode: .fit)
        .clipped()
        // Hairline tile edge so cells read as crisp panels, not a seamless blob.
        .cardStroke(0)
        // Smart Focus spotlight — a clean accent border on the active camera.
        .overlay {
            if active {
                Rectangle()
                    .strokeBorder(GlassTheme.accent, lineWidth: 2.5)
            }
        }
        // Semantic motion chip (orange = motion) consistent with the app's status chips.
        .overlay(alignment: .topTrailing) {
            if active {
                HStack(spacing: 4) {
                    Circle().fill(GlassTheme.orange).frame(width: 5, height: 5)
                    Text("MOTION")
                        .font(.system(size: columns > 2 ? 9 : 10, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                .padding(GlassTheme.Space.s)
                .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tap()
            onTap()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(titleize(camera.name)) camera\(isLive ? ", live" : ""). Opens live view.")
        .accessibilityAddTraits(.isButton)
    }
}
