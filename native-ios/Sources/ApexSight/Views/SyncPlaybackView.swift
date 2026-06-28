import AVFoundation
import SwiftUI

// MARK: - Synced multi-camera playback ("time travel")
//
// Pick a moment and watch every camera replay it in sync — event reconstruction
// across the whole property. Each camera plays its own Frigate VOD window
// (`recordingHLSURL`, where t=0 maps to `windowStart`), so seeking them all to the
// same offset lines them up on one wall clock. A master clock drives a shared
// scrubber + play/pause, and a light drift corrector nudges stragglers back.

/// An event on the shared timeline (position 0…1 across the window + a color by object).
struct SyncMarker: Identifiable {
    let id: String
    let fraction: Double
    let color: Color
}

@MainActor
final class SyncPlaybackModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published var fraction: Double          // 0 = windowStart, 1 = windowEnd
    @Published private(set) var readyCount = 0
    @Published private(set) var failed: Set<String> = []
    /// Event ticks across all visible cameras in the window — so the scrubber shows where
    /// the action is and you can jump straight to it.
    @Published private(set) var markers: [SyncMarker] = []

    let windowStart: Double
    let windowEnd: Double
    private(set) var order: [String] = []          // camera names, stable display order
    private var players: [String: AVPlayer] = [:]
    private var statusObs: [NSKeyValueObservation] = []
    private var driftTask: Task<Void, Never>?
    private var isScrubbing = false

    /// Land within ~0.8s of the target — exact seeks over HLS are sluggish and we only
    /// need cameras visually aligned, not frame-locked.
    private let tolerance = CMTime(seconds: 0.8, preferredTimescale: 600)

    var duration: Double { max(1, windowEnd - windowStart) }
    /// Absolute epoch the playhead is currently on.
    var currentEpoch: Double { windowStart + fraction * duration }

    init(windowStart: Double, windowEnd: Double, startAtFraction: Double = 1.0) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.fraction = min(1, max(0, startAtFraction))
    }

    func player(for camera: String) -> AVPlayer? { players[camera] }

    func load(cameras: [FrigateCamera], client: FrigateClient) {
        order = cameras.map(\.name)
        for cam in cameras {
            let url = client.recordingHLSURL(camera: cam.name, start: windowStart, end: windowEnd)
            let item = client.playerItem(for: url)
            let p = AVPlayer(playerItem: item)
            p.isMuted = true
            p.automaticallyWaitsToMinimizeStalling = true
            players[cam.name] = p
            // Track readiness/failure per camera so the grid can show a placeholder for
            // cameras with no footage in this window instead of a dead black cell.
            let name = cam.name
            statusObs.append(item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self else { return }
                    switch item.status {
                    case .readyToPlay: self.readyCount += 1
                    case .failed: self.failed.insert(name)
                    default: break
                    }
                }
            })
        }
        seekAll(toFraction: fraction)
        loadMarkers(cameras: Set(order), client: client)
    }

    /// Fetch detections in the window for the visible cameras and place them on the timeline.
    private func loadMarkers(cameras: Set<String>, client: FrigateClient) {
        let after = Date(timeIntervalSince1970: windowStart)
        let before = Date(timeIntervalSince1970: windowEnd)
        Task { [weak self] in
            let events = (try? await client.events(after: after, before: before, limit: 300)) ?? []
            guard let self else { return }
            let ticks: [SyncMarker] = events.compactMap { e in
                guard cameras.contains(e.camera), let t = e.startTime else { return nil }
                let f = (t - self.windowStart) / self.duration
                guard f >= 0, f <= 1 else { return nil }
                return SyncMarker(id: e.id, fraction: f, color: Self.color(for: e.label))
            }
            self.markers = ticks
        }
    }

    static func color(for label: String) -> Color {
        switch label.lowercased() {
        case "person": return GlassTheme.accent
        case "car", "vehicle", "truck", "motorcycle", "bus": return GlassTheme.green
        case "dog", "cat", "animal", "bird": return GlassTheme.orange
        case "package": return GlassTheme.purple
        default: return GlassTheme.secondary
        }
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard !players.isEmpty else { return }
        isPlaying = true
        // If we're parked at the very end, restart from the top so play does something.
        if fraction >= 0.999 { seekAll(toFraction: 0) }
        players.values.forEach { $0.play() }
        startDriftCorrection()
    }

    func pause() {
        isPlaying = false
        driftTask?.cancel(); driftTask = nil
        players.values.forEach { $0.pause() }
    }

    /// Scrub: seek every player to the same offset. Called live while dragging.
    func scrub(toFraction f: Double) {
        isScrubbing = true
        fraction = min(1, max(0, f))
        seekAll(toFraction: fraction)
    }

    func endScrub() { isScrubbing = false }

    private func seekAll(toFraction f: Double) {
        let t = CMTime(seconds: f * duration, preferredTimescale: 600)
        for p in players.values { p.seek(to: t, toleranceBefore: tolerance, toleranceAfter: tolerance) }
    }

    /// Once per second: advance the shared playhead from a master player and pull any
    /// camera that has drifted >1s back into line.
    private func startDriftCorrection() {
        driftTask?.cancel()
        driftTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isPlaying, !self.isScrubbing else { continue }
                // Master = the furthest-along ready player (most likely to have real frames).
                let times = self.players.values.compactMap { p -> Double? in
                    let s = p.currentTime().seconds; return s.isFinite ? s : nil
                }
                guard let master = times.max() else { continue }
                self.fraction = min(1, max(0, master / self.duration))
                for p in self.players.values {
                    let d = p.currentTime().seconds
                    if d.isFinite, abs(d - master) > 1.0 {
                        await p.seek(to: CMTime(seconds: master, preferredTimescale: 600),
                                     toleranceBefore: self.tolerance, toleranceAfter: self.tolerance)
                    }
                }
                if master >= self.duration - 0.5 { self.pause() }   // reached the end
            }
        }
    }

    func teardown() {
        driftTask?.cancel(); driftTask = nil
        statusObs.forEach { $0.invalidate() }; statusObs.removeAll()
        for p in players.values { p.pause(); p.replaceCurrentItem(with: nil) }
        players.removeAll()
    }

    deinit {
        driftTask?.cancel()
        statusObs.forEach { $0.invalidate() }
    }
}

// MARK: - Minimal, non-interactive AVPlayer layer for the grid cells.

private struct SyncPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> PlayerLayerHostView {
        let v = PlayerLayerHostView()
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.player = player
        return v
    }

    func updateUIView(_ uiView: PlayerLayerHostView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }

    final class PlayerLayerHostView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        override init(frame: CGRect) { super.init(frame: frame); backgroundColor = .black }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    }
}

// MARK: - Sync playback screen

struct SyncPlaybackView: View {
    let cameras: [FrigateCamera]
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var model: SyncPlaybackModel
    @State private var dragging = false
    /// The cameras actually used — falls back to a fetch when none were passed in (e.g. a
    /// cold-launch deep link before the camera list loaded).
    @State private var resolvedCameras: [FrigateCamera] = []
    @State private var loadedOnce = false

    init(cameras: [FrigateCamera], anchorEpoch: Double) {
        self.cameras = cameras
        let windowSeconds: Double = 3600
        let end = anchorEpoch
        let start = end - windowSeconds
        // Open ~90s before the live edge so a real recorded frame is on screen immediately —
        // the exact live edge usually has no decodable frame yet (shows black).
        let startFraction = (windowSeconds - 90) / windowSeconds
        _model = StateObject(wrappedValue: SyncPlaybackModel(windowStart: start, windowEnd: end, startAtFraction: startFraction))
    }

    private var columns: [GridItem] {
        let count = resolvedCameras.count <= 2 ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: GlassTheme.Space.s), count: count)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GlassTheme.base.ignoresSafeArea()
                VStack(spacing: 0) {
                    grid
                    controls
                }
            }
            .navigationTitle("Sync Playback")
            .navigationBarTitleDisplayMode(.inline)
            .glassNavBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(GlassTheme.accent)
                }
            }
            .task {
                guard !loadedOnce, let client = appState.client else { return }
                loadedOnce = true
                // Use the cameras passed in; if none (cold-launch deep link), fetch the list.
                let cams = cameras.isEmpty ? ((try? await client.cameras()) ?? []) : cameras
                resolvedCameras = cams
                model.load(cameras: cams, client: client)
            }
            .onDisappear { model.teardown() }
        }
    }

    @ViewBuilder
    private var grid: some View {
        if resolvedCameras.isEmpty {
            if loadedOnce {
                EmptyStateView(icon: "clock.badge.questionmark",
                               title: "No Cameras",
                               message: "Couldn't load cameras for synced playback.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(GlassTheme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            cameraGrid
        }
    }

    private var cameraGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: GlassTheme.Space.s) {
                ForEach(resolvedCameras) { camera in
                    ZStack {
                        RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous)
                            .fill(Color.black)
                        SyncPlayerLayerView(player: model.player(for: camera.name))
                        if model.failed.contains(camera.name) {
                            VStack(spacing: 6) {
                                Image(systemName: "video.slash.fill").font(.title3)
                                Text("No recording").font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(GlassTheme.tertiary)
                        }
                        VStack {
                            Spacer()
                            HStack {
                                Text(titleize(camera.name))
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(.black.opacity(0.5), in: Capsule())
                                Spacer()
                            }
                            .padding(8)
                        }
                    }
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
                    .cardStroke(GlassTheme.Radius.tile)
                }
            }
            .padding(GlassTheme.Space.m)
        }
    }

    private var controls: some View {
        VStack(spacing: GlassTheme.Space.s) {
            // Activity strip: a colored tick for every detection across all cameras in the
            // window, so you can see where the action is at a glance.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(GlassTheme.surfaceHigh)
                        .frame(height: 3)
                        .frame(maxHeight: .infinity, alignment: .center)
                    ForEach(model.markers) { m in
                        Capsule()
                            .fill(m.color)
                            .frame(width: 2.5, height: 16)
                            .offset(x: m.fraction * max(0, geo.size.width - 2.5))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                // Tap or drag the activity strip to jump straight to that moment.
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            model.scrub(toFraction: min(1, max(0, v.location.x / geo.size.width)))
                        }
                        .onEnded { _ in Haptics.tap(); model.endScrub() }
                )
            }
            .frame(height: 16)

            // Shared timeline scrubber across all cameras.
            Slider(
                value: Binding(
                    get: { model.fraction },
                    set: { model.scrub(toFraction: $0) }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    dragging = editing
                    if !editing { model.endScrub() }
                }
            )
            .tint(GlassTheme.accent)

            HStack {
                Text(timeLabel(model.currentEpoch))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(GlassTheme.secondary)
                Spacer()
                Button {
                    Haptics.tap()
                    model.togglePlay()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(GlassTheme.accent)
                        .symbolRenderingMode(.hierarchical)
                }
                .accessibilityLabel(model.isPlaying ? "Pause all cameras" : "Play all cameras")
                Spacer()
                Text("LIVE −\(Int((1 - model.fraction) * model.duration / 60))m")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(GlassTheme.tertiary)
            }
        }
        .padding(.horizontal, GlassTheme.Space.l)
        .padding(.top, GlassTheme.Space.s)
        .padding(.bottom, GlassTheme.Space.m)
        .background(.ultraThinMaterial)
    }

    private func timeLabel(_ epoch: Double) -> String {
        let d = Date(timeIntervalSince1970: epoch)
        let f = DateFormatter(); f.dateFormat = "h:mm:ss a"
        return f.string(from: d)
    }
}
