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
    @StateObject private var talk = TwoWayTalkController()

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
        // Keep the bottom tab pill bar present in the full-screen view (the user wants it there,
        // like the home screen). Only our own top/bottom camera chrome auto-hides for immersion.
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
        // Keep the chrome pinned up while a control is active; re-arm the auto-hide once the
        // user finishes (closes PTZ, releases Talk, dismisses the controls sheet).
        .onChange(of: showPTZ) { _, on in on ? revealChrome() : scheduleHideChrome() }
        .onChange(of: talk.isActive) { _, active in active ? revealChrome() : scheduleHideChrome() }
        .onChange(of: showCameraControls) { _, shown in shown ? revealChrome() : scheduleHideChrome() }
        .onDisappear { hideTask?.cancel(); talk.stop() }
        .sheet(isPresented: $showCameraControls) {
            CameraQuickControlsSheet(camera: camera)
                .environmentObject(appState)
        }
    }

    // MARK: - Immersive chrome (auto-hide, tap to toggle)

    /// Keep the chrome up while the user is actively using a control — auto-hiding the bars
    /// mid-gesture would yank the PTZ joystick, the push-to-talk button, or an open sheet away.
    private var interactionActive: Bool { showPTZ || talk.isActive || showCameraControls }

    private func scheduleHideChrome() {
        hideTask?.cancel()
        // Don't arm the hide timer while a control is in use; it re-arms when interaction ends.
        guard !interactionActive else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, !interactionActive else { return }
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
                overlayControlsVisible: showChrome,
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
                    .liquidGlass(in: Circle(), interactive: true, fallbackMaterial: .ultraThinMaterial)
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
                    .liquidGlass(in: Capsule(), interactive: true, fallbackMaterial: .ultraThinMaterial)
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
                        .liquidGlass(in: Circle(), tint: showPTZ ? GlassTheme.accent : nil, interactive: true, fallbackMaterial: .ultraThinMaterial)
                        .foregroundStyle(showPTZ ? GlassTheme.accent : GlassTheme.primary)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Pan, tilt, zoom controls")
                .accessibilityValue(showPTZ ? "Shown" : "Hidden")
            }
        }
        .padding(.horizontal, GlassTheme.Space.l)
        .glassGroup(spacing: GlassTheme.Space.s)
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
                    if appState.twoWayCameras.contains(camera.name) {
                        talkButton
                    }
                }
            }
            // Morph the action-button glass as a single system (so PTZ/Talk fluidly join in).
            .glassGroup(spacing: GlassTheme.Space.xl)
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
                .liquidGlass(in: Circle(), interactive: true, fallbackMaterial: .ultraThinMaterial)
                .foregroundStyle(GlassTheme.primary)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(GlassTheme.secondary)
        }
    }

    /// Push-to-talk: press and hold to stream the mic to the camera's speaker; release to stop.
    private var talkButton: some View {
        let active = talk.isActive
        let connecting = talk.status == .connecting
        return VStack(spacing: GlassTheme.Space.s) {
            Image(systemName: active ? "mic.fill" : "mic")
                .font(.system(size: 21, weight: .semibold))
                .symbolEffect(.variableColor, options: reduceMotion ? .nonRepeating : .repeating, isActive: connecting)
                .frame(width: 54, height: 54)
                .liquidGlass(in: Circle(), tint: active ? GlassTheme.red : nil, interactive: true, fallbackMaterial: .ultraThinMaterial)
                .foregroundStyle(active ? .white : GlassTheme.primary)
                .scaleEffect(active ? 1.08 : 1)
                .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: active)
            Text(connecting ? "Connecting…" : (active ? "Talking…" : "Hold to Talk"))
                .font(.caption.weight(.medium))
                .foregroundStyle(active ? GlassTheme.red : GlassTheme.secondary)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard talk.status == .idle, let client = appState.client else { return }
                    Haptics.tap()
                    Task { await talk.start(cameraTwoWaySource: "\(camera.name)_twoway", client: client) }
                }
                .onEnded { _ in talk.stop() }
        )
        .accessibilityLabel("Push to talk")
        .accessibilityHint("Press and hold to speak through the camera")
    }
}
