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
    // Smart Focus: spotlight + scroll to the camera where Frigate just detected something.
    @AppStorage("multiview.smartFocus") private var smartFocus = true
    @State private var activeCameraName: String?
    @State private var lastEventID: String?
    @State private var clearWork: DispatchWorkItem?

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
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20, weight: .black))
                            .foregroundStyle(GlassTheme.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            Haptics.select()
                            smartFocus.toggle()
                            if !smartFocus { activeCameraName = nil }
                        } label: {
                            Image(systemName: "sparkles")
                                .font(.system(size: 16, weight: .black))
                                .foregroundStyle(smartFocus ? GlassTheme.cyan : GlassTheme.tertiary)
                        }
                        .accessibilityLabel(smartFocus ? "Smart Focus on" : "Smart Focus off")
                        columnPicker
                    }
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
                                cameraCell(displayedCameras[idx])
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
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { activeCameraName = name }
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.3)) {
                if activeCameraName == name { activeCameraName = nil }
            }
        }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private var cameraRows: [[Int]] {
        let count = displayedCameras.count
        return stride(from: 0, to: count, by: columns).map { start in
            Array(start..<min(start + columns, count))
        }
    }

    private func cameraCell(_ camera: FrigateCamera) -> some View {
        let active = camera.name == activeCameraName
        return ZStack(alignment: .bottomLeading) {
            Color.black
            // WebRTC-first (instant, Metal); falls back to HLS/MJPEG per camera internally.
            LiveVideoPlayerView(camera: camera)
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
        // Smart Focus spotlight — a glowing border + MOTION tag on the active camera.
        .overlay {
            if active {
                Rectangle()
                    .strokeBorder(GlassTheme.cyan, lineWidth: 3)
                    .shadow(color: GlassTheme.cyan.opacity(0.9), radius: 8)
            }
        }
        .overlay(alignment: .topTrailing) {
            if active {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                    Text("MOTION")
                }
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(.black)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(GlassTheme.cyan, in: Capsule())
                .padding(6)
                .transition(.scale.combined(with: .opacity))
            }
        }
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
