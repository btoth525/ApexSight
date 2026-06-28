import SwiftUI

struct LiveStreamView: View {
    let camera: FrigateCamera
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var streamMode: StreamMode = .live
    @State private var isLive = false
    @State private var showPTZ = false
    @State private var capability: CameraCapability?
    @State private var reloadToken = UUID()
    @State private var showChrome = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showCameraControls = false
    @State private var showDetectionOverlay = true

    enum StreamMode: String, CaseIterable {
        case live = "Live"
        case snapshot = "Snapshot"
    }

    private var isBirdseye: Bool { camera.name == "birdseye" }

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
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showChrome)
        }
        .navigationBarHidden(true)
        .statusBarHidden(!showChrome)
        .swipeBackEnabled()   // restore edge-swipe-back despite the hidden nav bar
        .task {
            capability = appState.capabilities.first(where: { $0.camera == camera.name })
            scheduleHideChrome()
        }
        .onChange(of: streamMode) { _, _ in
            isLive = false
            reloadToken = UUID()
            revealChrome()
        }
        .onDisappear { hideTask?.cancel() }
        .sheet(isPresented: $showCameraControls) {
            CameraQuickControlsSheet(camera: camera)
                .environmentObject(appState)
        }
    }

    // MARK: - Immersive chrome (auto-hide, tap to toggle)

    private func scheduleHideChrome() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { showChrome = false }
        }
    }

    private func revealChrome() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { showChrome = true }
        scheduleHideChrome()
    }

    private func toggleChrome() {
        Haptics.tap()
        if showChrome {
            hideTask?.cancel()
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { showChrome = false }
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
        ZStack {
            HLSLivePlayerView(
                camera: camera,
                showControls: true,
                onSingleTap: { toggleChrome() },
                onPlaying: { playing in withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) { isLive = playing } }
            )
            .id(reloadToken)

            if showDetectionOverlay, let dets = appState.liveDetections[camera.name], !dets.isEmpty {
                DetectionOverlayView(detections: dets)
                    .allowsHitTesting(false)
            }
        }
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
        HStack(spacing: GlassTheme.Space.s) {
            Button {
                Haptics.tap()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay { Circle().strokeBorder(GlassTheme.separator, lineWidth: 1) }
                    .foregroundStyle(GlassTheme.primary)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Close live view")

            VStack(alignment: .leading, spacing: 2) {
                Text(isBirdseye ? "All Cameras" : titleize(camera.name))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(GlassTheme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: GlassTheme.Space.xs) {
                    statusIndicator
                    Text(statusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
            }

            Spacer(minLength: GlassTheme.Space.s)

            // Birdseye is live-only — no latest.jpg and no recordings.
            if !isBirdseye {
                Menu {
                    Picker("Stream", selection: $streamMode) {
                        ForEach(StreamMode.allCases, id: \.self) { mode in
                            Label(mode.rawValue, systemImage: icon(for: mode)).tag(mode)
                        }
                    }
                } label: {
                    HStack(spacing: GlassTheme.Space.xs) {
                        Image(systemName: icon(for: streamMode))
                            .font(.system(size: 12, weight: .semibold))
                        Text(streamMode.rawValue)
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(GlassTheme.primary)
                    .padding(.horizontal, GlassTheme.Space.m)
                    .frame(minHeight: 44)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay { Capsule().strokeBorder(GlassTheme.separator, lineWidth: 1) }
                }
                .accessibilityLabel("Stream source, currently \(streamMode.rawValue)")
            }

            if capability?.hasPtz == true {
                Button {
                    Haptics.select()
                    showPTZ.toggle()
                } label: {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(showPTZ ? AnyShapeStyle(GlassTheme.accent.opacity(0.30)) : AnyShapeStyle(.ultraThinMaterial), in: Circle())
                        .overlay { Circle().strokeBorder(showPTZ ? GlassTheme.accent.opacity(0.55) : GlassTheme.separator, lineWidth: 1) }
                        .foregroundStyle(showPTZ ? GlassTheme.accent : GlassTheme.primary)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Pan, tilt, zoom controls")
                .accessibilityValue(showPTZ ? "Shown" : "Hidden")
            }
        }
        .padding(.horizontal, GlassTheme.Space.l)
        .padding(.top, 54)
    }

    /// Status indicator: StatusDot for live/connecting states, a small solid dot for snapshot.
    @ViewBuilder
    private var statusIndicator: some View {
        switch streamMode {
        case .live:
            StatusDot(state: isLive ? .live : .offline)
        case .snapshot:
            Circle()
                .fill(GlassTheme.orange)
                .frame(width: 8, height: 8)
        }
    }

    private var statusColor: Color {
        switch streamMode {
        case .snapshot: return GlassTheme.orange
        case .live: return isLive ? GlassTheme.green : GlassTheme.secondary
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
        VStack(spacing: GlassTheme.Space.l) {
            if showPTZ, let client = appState.client {
                PTZControlView(cameraName: camera.name, client: client)
                    .padding(.horizontal, GlassTheme.Space.xxl)
            }

            HStack(spacing: GlassTheme.Space.xl) {
                actionButton(icon: "arrow.clockwise", label: "Refresh") {
                    isLive = false
                    reloadToken = UUID()
                }
                if !isBirdseye {
                    actionButton(icon: "photo", label: "Snapshot") {
                        streamMode = .snapshot
                    }
                    NavigationLink {
                        RecordingBrowserView(camera: camera)
                    } label: {
                        actionButtonContent(icon: "clock.arrow.circlepath", label: "Timeline")
                    }
                    .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
                    .accessibilityLabel("Open recording timeline")
                    actionButton(icon: "slider.horizontal.3", label: "Controls") {
                        showCameraControls = true
                    }
                }
            }
            .padding(.horizontal, GlassTheme.Space.l)
            .padding(.bottom, 40)
        }
    }

    private func actionButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            actionButtonContent(icon: icon, label: label)
        }
        .accessibilityLabel(label)
    }

    private func actionButtonContent(icon: String, label: String) -> some View {
        VStack(spacing: GlassTheme.Space.s) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .semibold))
                .frame(width: 54, height: 54)
                .background(.ultraThinMaterial, in: Circle())
                .overlay { Circle().strokeBorder(GlassTheme.separator, lineWidth: 1) }
                .foregroundStyle(GlassTheme.primary)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(GlassTheme.secondary)
        }
    }
}
