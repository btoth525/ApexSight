import SwiftUI
import UIKit

struct LiveStreamView: View {
    let camera: FrigateCamera
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var streamMode: StreamMode = .live
    @State private var isLive = false
    @State private var showPTZ = false
    /// Whether THIS camera actually reports PTZ features — resolved lazily on open (one
    /// ptz/info call), so the control only appears on cameras that can really pan/tilt and the
    /// camera wall never pays for a PTZ probe.
    @State private var hasPTZ = false
    @State private var reloadToken = UUID()
    @State private var showChrome = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showCameraControls = false
    @State private var showDetectionOverlay = true
    /// Mirrors the player's fit/fill state so the detection overlay maps boxes into the same rect.
    @State private var playerFillMode = false
    /// True while the fisheye dewarp owns the presentation — detection boxes are raw-frame
    /// coordinates and would land nowhere meaningful on a dewarped image, so hide them.
    private var playerDewarped: Bool {
        isFisheye && (fisheyeStore.config(for: camera.name).quadEnabled || dewarpMode != .off)
    }
    private var isFisheye: Bool { fisheyeStore.isFisheye(camera.name) }
    @State private var isPreparingShare = false
    @State private var sharePayload: SharePayload?
    @StateObject private var talk = TwoWayTalkController()
    // Unified control grid: the viewer owns mute, PiP, and the fisheye view state so every
    // control renders as ONE uniform button system (no floating overlay cluster).
    @State private var isMutedUI = true
    @StateObject private var pip = LivePiPController()
    @ObservedObject private var fisheyeStore = FisheyeStore.shared
    @State private var dewarpMode: DewarpMode = .ptz
    @State private var showCalibration = false
    // iOS 27 on-device "Ask AI" — describe who/what is on this live camera right now.
    @State private var aiResult: String?
    @State private var isAnalyzingAI = false
    @State private var showAIResult = false

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
        // Hide the bottom tab pill bar entirely in the full-screen viewer for a clean immersive
        // feed. (iOS only shows the small "minimized" pill as a scroll effect — there's no API
        // to force that compact state in a non-scrolling player, and a full-size bar over the
        // video is intrusive — so hiding it is the clean choice. Always hidden, not toggled with
        // the chrome, so there's no jarring slide-in/out.)
        .toolbar(.hidden, for: .tabBar)
        .swipeBackEnabled()   // restore edge-swipe-back despite the hidden nav bar
        .onAppear {
            // Reopen exactly how the user left this fisheye camera (mode rides in the pose).
            if isFisheye, let saved = DewarpMode(rawValue: fisheyeStore.pose(for: camera.name, pane: nil).mode) {
                dewarpMode = saved
            }
            #if DEBUG
            // Sim-driving hook (synthetic taps can't reach the control rows reliably).
            if let raw = UserDefaults(suiteName: ApexAppGroup.identifier)?
                .object(forKey: "apex.debug.dewarpMode") as? Int,
               let injected = DewarpMode(rawValue: Int32(raw)) {
                dewarpMode = injected
            }
            #endif
        }
        .onChange(of: dewarpMode) { _, newMode in
            // Persist the chosen view mode (including Raw) so this camera reopens — here
            // AND on the wall tile — exactly how the user left it.
            if isFisheye {
                var pose = fisheyeStore.pose(for: camera.name, pane: nil)
                pose.mode = newMode.rawValue
                fisheyeStore.savePose(camera.name, pane: nil, pose: pose)
            }
        }
        .sheet(isPresented: $showCalibration) {
            FisheyeCalibrationSheet(camera: camera)
                .presentationDetents([.height(360)])
                .presentationBackgroundInteraction(.enabled)
                .presentationBackground(.ultraThinMaterial)
        }
        .task {
            scheduleHideChrome()
            // Confirm real PTZ for this one camera (off the wall path, cancels if you leave).
            if !isBirdseye, let client = appState.client {
                hasPTZ = await client.ptzCapable(camera: camera.name)
            }
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
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: payload.items)
        }
        .sheet(isPresented: $showAIResult) {
            LiveAIResultSheet(cameraName: camera.name, isLoading: isAnalyzingAI, result: aiResult)
                .presentationDetents([.medium])
                .presentationBackground(.ultraThinMaterial)
        }
        .onChange(of: showAIResult) { _, shown in shown ? revealChrome() : scheduleHideChrome() }
    }

    /// On-device "Ask AI": describe who/what is on this live camera using the current snapshot,
    /// plus any legible text (plates/labels). Entirely on-device; gated to iOS 27 + AppleAI.
    @available(iOS 27.0, *)
    private func analyzeLive() async {
        guard !isAnalyzingAI, let client = appState.client else { return }
        isAnalyzingAI = true
        aiResult = nil
        showAIResult = true
        // Fetch the current frame FRESH and CLEAN (overlays off) so Vision sees the real scene, not
        // Frigate's burned-in timestamp/box. latest.jpg ignores the local cache, so it's live.
        guard let data = try? await client.imageData(from: client.cleanFrameURL(camera: camera.name)),
              let cg = UIImage(data: data)?.cgImage else {
            isAnalyzingAI = false
            aiResult = "Couldn't grab the current frame — check the connection and try again."
            return
        }
        async let scene = AppleAI.describeScene(in: cg, cameraName: camera.name)
        async let text = AppleAI.readText(in: cg)
        let (description, legibleText) = await (scene, text)
        var combined = description ?? "Couldn't analyze this frame on-device."
        if let legibleText, !legibleText.isEmpty { combined += "\n\n📄 Text seen: \(legibleText)" }
        isAnalyzingAI = false
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { aiResult = combined }
    }

    /// Grab the camera's current still and hand it to the share sheet (AirDrop / Messages / …).
    private func shareSnapshot() async {
        guard let client = appState.client else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }
        guard let data = try? await client.imageData(from: client.latestFrameURL(camera: camera.name)),
              let image = UIImage(data: data) else { return }
        sharePayload = SharePayload(image: image)
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
                pipController: pip,
                onSingleTap: { toggleChrome() },
                onPlaying: { playing in withAnimation(reduceMotion ? nil : .easeIn(duration: 0.2)) { isLive = playing } },
                externalControls: true,
                muted: isMutedUI,
                dewarpModeOverride: isFisheye ? dewarpMode : nil
            )
            .id(reloadToken)

            if showDetectionOverlay, !playerDewarped,
               let dets = appState.liveDetections[camera.name], !dets.isEmpty {
                DetectionOverlayView(detections: dets, videoAspect: camera.aspectRatio, fill: playerFillMode)
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
                    .font(.system(size: 21, weight: .semibold))
                    .frame(width: 54, height: 54)
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
                    .frame(minHeight: 54)
                    .liquidGlass(in: Capsule(), interactive: true, fallbackMaterial: .ultraThinMaterial)
                }
                .accessibilityLabel("Stream source, currently \(streamMode.rawValue)")
            }

            if hasPTZ {
                Button {
                    Haptics.select()
                    showPTZ.toggle()
                } label: {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 21, weight: .semibold))
                        .frame(width: 54, height: 54)
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

            // ONE uniform control system: every action — stream, media, audio, PiP, fisheye —
            // renders as the same 54pt labeled button, chunked into centered rows of up to
            // five so nothing is ever clipped, scrolled, or floating off in a corner.
            actionGrid
                .frame(maxWidth: .infinity)
                .padding(.bottom, 40)
        }
    }

    /// Centered rows of ≤5 uniform buttons — 7 buttons → 4+3, 12 → 4+4+4, always balanced.
    private var actionGrid: some View {
        let items = actionItems
        let perRow = 5
        let rowCount = max(1, Int(ceil(Double(items.count) / Double(perRow))))
        let base = items.count / rowCount
        let extra = items.count % rowCount   // first `extra` rows get one more
        var rows: [[Int]] = []
        var cursor = 0
        for r in 0..<rowCount {
            let size = base + (r < extra ? 1 : 0)
            rows.append(Array(cursor..<(cursor + size)))
            cursor += size
        }
        return VStack(spacing: GlassTheme.Space.m) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: GlassTheme.Space.m) {
                    // Fixed-width cells → circles are evenly spaced no matter how wide each
                    // label is ("Refresh" vs "Hold to Talk"). Without this the gaps between
                    // circles varied with label width.
                    ForEach(rows[r], id: \.self) { items[$0].frame(width: Self.actionCellWidth) }
                }
            }
        }
        .padding(.horizontal, GlassTheme.Space.l)
    }

    /// Uniform action-button cell width — the circle is 54pt; the extra room lets labels
    /// like "Hold to Talk" sit under it without changing the button's footprint.
    private static let actionCellWidth: CGFloat = 74

    /// The live-view action buttons, in order — collected so they can render as one row or
    /// wrap to two (see `ViewThatFits` above). Type-erased because the set is conditional
    /// (birdseye, Ask AI availability, two-way audio).
    private var actionItems: [AnyView] {
        var items: [AnyView] = [
            AnyView(actionButton(icon: "arrow.clockwise", label: "Refresh") {
                isLive = false
                reloadToken = UUID()
            })
        ]
        guard !isBirdseye else { return items }

        items.append(AnyView(actionButton(icon: "photo", label: "Snapshot") {
            streamMode = .snapshot
        }))
        items.append(AnyView(
            NavigationLink {
                RecordingBrowserView(camera: camera)
            } label: {
                actionButtonContent(icon: "clock.arrow.circlepath", label: "Timeline")
            }
            .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
            .accessibilityLabel("Open recording timeline")
        ))
        items.append(AnyView(actionButton(icon: "slider.horizontal.3", label: "Controls") {
            showCameraControls = true
        }))
        if #available(iOS 27.0, *), AppleAI.visionAIAvailable, AICameraSettings.isEnabled(camera.name) {
            items.append(AnyView(actionButton(icon: "sparkles", label: "Ask AI") {
                Task { await analyzeLive() }
            }))
        }
        items.append(AnyView(actionButton(icon: "square.and.arrow.up", label: "Share") {
            Task { await shareSnapshot() }
        }))
        if appState.twoWayCameras.contains(camera.name) {
            items.append(AnyView(talkButton))
        }

        // Player controls — same uniform buttons, no separate floating cluster.
        items.append(AnyView(actionButton(
            icon: isMutedUI ? "speaker.slash.fill" : "speaker.wave.2.fill",
            label: isMutedUI ? "Muted" : "Audio"
        ) {
            isMutedUI.toggle()
        }))
        // Only show PiP where it can ACTUALLY start — Picture-in-Picture needs a real
        // AVPlayerLayer, which the fisheye Metal view and the MJPEG fallback don't have.
        // `isPossible` flips true once the controller attaches to a live HLS layer, so the
        // button appears only on cameras where tapping it works (no more dead button).
        if pip.isPossible {
            items.append(AnyView(actionButton(
                icon: pip.isActive ? "pip.exit" : "pip.enter",
                label: "PiP"
            ) {
                pip.toggle()
            }))
        }

        // Fisheye controls (only for cameras the user marked fisheye in Settings).
        if isFisheye {
            let quadOn = fisheyeStore.config(for: camera.name).quadEnabled
            let locked = fisheyeStore.config(for: camera.name).locked
            items.append(AnyView(actionButton(
                icon: quadOn ? "rectangle.fill" : "square.split.2x2",
                label: quadOn ? "Single" : "Quad"
            ) {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    fisheyeStore.setQuadEnabled(camera.name, enabled: !quadOn)
                }
            }))
            if !quadOn {
                items.append(AnyView(actionButton(icon: dewarpMode.icon, label: "View") {
                    let all = DewarpMode.allCases
                    let next = all[(all.firstIndex(of: dewarpMode).map { ($0 + 1) % all.count }) ?? 0]
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { dewarpMode = next }
                }))
            }
            if playerDewarped {
                items.append(AnyView(actionButton(
                    icon: locked ? "lock.fill" : "lock.open",
                    label: locked ? "Locked" : "Lock"
                ) {
                    fisheyeStore.setLocked(camera.name, locked: !locked)
                }))
                if !locked {
                    items.append(AnyView(actionButton(icon: "dial.low", label: "Tune") {
                        showCalibration = true
                    }))
                }
            }
        }
        return items
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
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)   // stay within the fixed cell — never reflow the grid
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
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                // The grid cell is a fixed width, so the mid-hold caption swap
                // ("Hold to Talk" → "Talking…") can't reflow the layout and destroy the gesture.
                .frame(maxWidth: .infinity)
        }
        .contentShape(Circle())
        // Push-to-talk lives inside the horizontal control ScrollView, so a plain
        // DragGesture(minimumDistance: 0) loses the scroll-vs-press arbitration and the row
        // scrolls instead of talking. Sequencing a short LongPress *before* the drag claims the
        // touch (a scroll needs movement; the long-press needs the finger to hold still briefly),
        // then the trailing drag keeps Talk engaged for as long as the finger stays down.
        .gesture(
            LongPressGesture(minimumDuration: 0.12, maximumDistance: 60)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .onChanged { value in
                    // `.second(true, _)` = the long-press fired and the hold/drag is now active.
                    guard case .second(true, _) = value else { return }
                    guard talk.status == .idle, let client = appState.client else { return }
                    Haptics.tap()
                    talk.begin(cameraTwoWaySource: "\(camera.name)_twoway", client: client)
                }
                .onEnded { _ in talk.stop() }
        )
        .accessibilityLabel("Push to talk")
        .accessibilityHint("Press and hold to speak through the camera")
    }
}

/// Bottom sheet that presents the on-device "Ask AI" result for a live camera. Pure local
/// inference — the copy makes the privacy guarantee explicit.
private struct LiveAIResultSheet: View {
    let cameraName: String
    let isLoading: Bool
    let result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
            HStack(spacing: GlassTheme.Space.s) {
                Image(systemName: "sparkles").foregroundStyle(GlassTheme.accent)
                Text("On-Device Analysis")
                    .font(.headline)
                    .foregroundStyle(GlassTheme.primary)
                Spacer()
            }
            Text(titleize(cameraName))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(GlassTheme.secondary)

            if isLoading {
                HStack(spacing: GlassTheme.Space.s) {
                    ProgressView().tint(.white)
                    Text("Analyzing this frame on your iPhone…")
                        .font(.callout)
                        .foregroundStyle(GlassTheme.secondary)
                }
                .padding(.top, GlassTheme.Space.s)
            } else if let result {
                ScrollView {
                    Text(result)
                        .font(.system(size: 16))
                        .foregroundStyle(GlassTheme.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer()
            Label("Runs entirely on your device — no image leaves your iPhone.",
                  systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(GlassTheme.tertiary)
        }
        .padding(GlassTheme.Space.xl)
    }
}
