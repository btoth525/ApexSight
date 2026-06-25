import SwiftUI

struct LiveStreamView: View {
    let camera: FrigateCamera
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var streamMode: StreamMode = .live
    @State private var isLive = false
    @State private var showPTZ = false
    @State private var capability: CameraCapability?
    @State private var reloadToken = UUID()
    @State private var showChrome = true
    @State private var hideWork: DispatchWorkItem?

    enum StreamMode: String, CaseIterable {
        case live = "Live"
        case snapshot = "Snapshot"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            content
                .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            .opacity(showChrome ? 1 : 0)
            .allowsHitTesting(showChrome)
            .animation(.easeInOut(duration: 0.25), value: showChrome)
        }
        .navigationBarHidden(true)
        .statusBarHidden(!showChrome)
        .task {
            capability = appState.capabilities.first(where: { $0.camera == camera.name })
            scheduleHideChrome()
        }
        .onChange(of: streamMode) { _, _ in
            isLive = false
            reloadToken = UUID()
            revealChrome()
        }
        .onDisappear { hideWork?.cancel() }
    }

    // MARK: - Immersive chrome (auto-hide, tap to toggle)

    private func scheduleHideChrome() {
        hideWork?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 0.25)) { showChrome = false }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func revealChrome() {
        withAnimation(.easeInOut(duration: 0.25)) { showChrome = true }
        scheduleHideChrome()
    }

    private func toggleChrome() {
        if showChrome {
            hideWork?.cancel()
            withAnimation(.easeInOut(duration: 0.25)) { showChrome = false }
        } else {
            revealChrome()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch streamMode {
        case .live:
            liveHLS
        case .snapshot:
            snapshotView
        }
    }

    private var liveHLS: some View {
        // Pure WebRTC: instant, Metal-rendered, hardware-decoded. No HLS/MJPEG.
        LiveVideoPlayerView(
            camera: camera,
            showControls: true,
            onSingleTap: { toggleChrome() },
            onPlaying: { playing in withAnimation(.easeIn(duration: 0.2)) { isLive = playing } }
        )
        .id(reloadToken)
    }

    private var snapshotView: some View {
        ZoomableScrollView(onSingleTap: { toggleChrome() }) {
            if let client = appState.client {
                RemoteImage(url: client.latestFrameURL(camera: camera.name), contentMode: .fit)
                    .id(reloadToken)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .black))
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(titleize(camera.name))
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(statusColor)
                }
            }

            Spacer(minLength: 6)

            Menu {
                Picker("Stream", selection: $streamMode) {
                    ForEach(StreamMode.allCases, id: \.self) { mode in
                        Label(mode.rawValue, systemImage: icon(for: mode)).tag(mode)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: icon(for: streamMode))
                        .font(.system(size: 12, weight: .black))
                    Text(streamMode.rawValue)
                        .font(.system(size: 12, weight: .heavy))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .black))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
            }

            if capability?.hasPtz == true {
                Button {
                    showPTZ.toggle()
                } label: {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 15, weight: .black))
                        .frame(width: 38, height: 38)
                        .background(showPTZ ? AnyShapeStyle(GlassTheme.cyan.opacity(0.4)) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 54)
    }

    private var statusColor: Color {
        switch streamMode {
        case .snapshot: return .orange
        case .live: return isLive ? .green : .yellow
        }
    }

    private var statusText: String {
        switch streamMode {
        case .snapshot: return "Snapshot"
        case .live: return isLive ? "Live" : "Connecting…"
        }
    }

    private func icon(for mode: StreamMode) -> String {
        switch mode {
        case .live: return "dot.radiowaves.up.forward"
        case .snapshot: return "photo.fill"
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 16) {
            if showPTZ, let client = appState.client {
                PTZControlView(cameraName: camera.name, client: client)
                    .padding(.horizontal, 24)
            }

            HStack(spacing: 20) {
                actionButton(icon: "arrow.clockwise", label: "Refresh") {
                    isLive = false
                    reloadToken = UUID()
                }
                actionButton(icon: "photo", label: "Snapshot") {
                    streamMode = .snapshot
                }
                NavigationLink {
                    RecordingBrowserView(camera: camera)
                } label: {
                    actionButtonContent(icon: "clock.arrow.circlepath", label: "Timeline")
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
    }

    private func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            actionButtonContent(icon: icon, label: label)
        }
    }

    private func actionButtonContent(icon: String, label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .bold))
                .frame(width: 52, height: 52)
                .background(.white.opacity(0.15), in: Circle())
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}
