import AVFoundation
import MetalKit
import SwiftUI

// MARK: - MTKView wrapper

/// Thin UIViewRepresentable around the Metal dewarp surface. All state lives in the
/// renderer's uniforms; SwiftUI gestures write them directly (plain floats — no lock).
struct MetalDewarpView: UIViewRepresentable {
    let renderer: DewarpRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.backgroundColor = .black
        view.isOpaque = true
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        // A reappear can hand us a freshly-built renderer while SwiftUI reuses the MTKView —
        // rewire the delegate so the view never keeps drawing through a dead renderer.
        if view.delegate !== renderer { view.delegate = renderer }
    }
}

// MARK: - Fisheye viewer (gestures + renderer lifecycle)

/// The full dewarped-fisheye experience for one camera: owns the renderer, follows the
/// live player across HLS reconnects, and maps drag → pan/tilt, pinch → zoom.
/// Where the user leaves the view aimed is saved per camera (and per quad pane) and
/// restored everywhere the camera renders — the viewer and the wall tile share it.
struct FisheyeDewarpView: View {
    let player: AVPlayer
    let camera: FrigateCamera
    let mode: DewarpMode
    /// nil = the single dewarped view's saved pose; 0–3 = a quad pane's own slot.
    var paneIndex: Int? = nil
    /// Wall tiles render the saved view with gestures off (tap opens the viewer).
    var interactive: Bool = true
    /// Provided by the quad view so all four panes share ONE frame tap. When nil, this
    /// view owns its own source (the single dewarped view).
    var sharedSource: FisheyeFrameSource? = nil
    /// Single tap toggles the host's immersive chrome, same as the flat player.
    var onSingleTap: (() -> Void)? = nil

    @ObservedObject private var store = FisheyeStore.shared
    @State private var renderer: DewarpRenderer?
    /// Owned frame source for the single view (unused when `sharedSource` is set).
    @State private var ownSource: FisheyeFrameSource?
    /// Gesture anchors — captured at the first change of each gesture so the whole
    /// drag/pinch is relative to where it started, not cumulative per-event.
    @State private var dragAnchor: (pan: Float, tilt: Float)?
    @State private var zoomAnchor: Float?

    /// PTZ lock: the view can't be nudged; taps still work.
    private var gesturesEnabled: Bool {
        interactive && !store.config(for: camera.name).locked
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard let renderer, mode != .off, gesturesEnabled else { return }
                // A two-finger pinch also moves the touch centroid, which fires this
                // drag simultaneously — pan/tilt swung wildly while zooming (and the
                // garbage got SAVED). While a pinch is live, zoom owns the touch.
                guard zoomAnchor == nil else {
                    dragAnchor = nil
                    return
                }
                if dragAnchor == nil {
                    dragAnchor = (renderer.uniforms.pan, renderer.uniforms.tilt)
                }
                guard let anchor = dragAnchor else { return }
                // Grab-the-scene on BOTH axes — content follows the finger. The axes
                // need OPPOSITE signs (pan −, tilt +) because screen-x runs with
                // azimuth while screen-y runs against elevation; same-sign variants
                // ship one axis inverted (pixel-diff-verified on the sim: drag right
                // → content right, drag down → content down).
                let s = 0.0045 / max(renderer.uniforms.zoom, 0.4)
                renderer.uniforms.pan = anchor.pan - Float(value.translation.width) * s
                if mode == .ptz {
                    let tilt = anchor.tilt + Float(value.translation.height) * s
                    renderer.uniforms.tilt = min(max(tilt, 0.05), .pi * 0.58)
                }
            }
            .onEnded { _ in
                dragAnchor = nil
                // A drag that was interrupted by a pinch has nothing new to save; a
                // clean drag saves its final aim.
                if zoomAnchor == nil { savePose() }
            }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                guard let renderer, mode != .off, gesturesEnabled else { return }
                if zoomAnchor == nil {
                    zoomAnchor = renderer.uniforms.zoom
                    // Kill any in-flight drag the pinch's first events started — its
                    // anchor is stale the moment two fingers are down.
                    dragAnchor = nil
                }
                guard let anchor = zoomAnchor else { return }
                renderer.uniforms.zoom = min(max(anchor * Float(scale), 0.5), 6)
            }
            .onEnded { _ in
                zoomAnchor = nil
                savePose()
            }
    }

    var body: some View {
        Group {
            if let renderer {
                MetalDewarpView(renderer: renderer)
                    .gesture(dragGesture.simultaneously(with: pinchGesture))
                    .onTapGesture(count: 2) { resetAim() }
                    .onTapGesture { onSingleTap?() }
            } else {
                Color.black
            }
        }
        .onAppear {
            // Use the quad's shared tap, or spin up our own for the single view.
            let source: FisheyeFrameSource
            if let sharedSource {
                source = sharedSource
            } else {
                let s = ownSource ?? FisheyeFrameSource(player: player)
                ownSource = s
                source = s
            }
            source.start()

            let r = DewarpRenderer()
            r.frameSource = source
            apply(config: store.config(for: camera.name), to: r)
            applyPose(store.pose(for: camera.name, pane: paneIndex), to: r)
            r.uniforms.mode = mode.rawValue
            renderer = r
        }
        .onDisappear {
            // Only tear down a source we own — the shared one is the quad's to manage.
            if sharedSource == nil { ownSource?.stop() }
        }
        .onChange(of: player) { _, newPlayer in
            // HLS reconnects rebuild the AVPlayer — repoint the frame tap (our own only;
            // the quad repoints the shared source itself).
            if sharedSource == nil { ownSource?.player = newPlayer }
        }
        .onChange(of: mode) { _, newMode in
            renderer?.uniforms.mode = newMode.rawValue
            // Mode persistence lives with the parent (it also sees the switch to Raw,
            // which unmounts this view); this view saves only the aim, on gesture end.
        }
        .onChange(of: store.configs[camera.name]) { _, _ in
            apply(config: store.config(for: camera.name), to: renderer)
            // Read-only surfaces (wall tile) follow the aim saved from the viewer live.
            // Interactive views skip this — their gestures are the source of that pose.
            if !interactive, let renderer {
                applyPose(store.pose(for: camera.name, pane: paneIndex), to: renderer)
            }
        }
        .accessibilityLabel("Dewarped fisheye view, \(mode.label). Drag to look around, pinch to zoom, double-tap to reset.")
    }

    /// Apply a saved aim, clamped to sane ranges — a pose saved by an earlier build's
    /// pinch/drag interference bug (or a bad write) must never wedge the view somewhere
    /// unusable.
    private func applyPose(_ pose: FisheyePose, to renderer: DewarpRenderer?) {
        guard let renderer else { return }
        renderer.uniforms.pan = pose.pan.isFinite ? pose.pan : 0
        renderer.uniforms.tilt = min(max(pose.tilt.isFinite ? pose.tilt : 0.9, 0.05), .pi * 0.58)
        renderer.uniforms.zoom = min(max(pose.zoom.isFinite ? pose.zoom : 1, 0.5), 6)
    }

    /// Double-tap: snap back to the default aim (and save it) — the escape hatch when
    /// the view ends up somewhere weird.
    private func resetAim() {
        guard let renderer, gesturesEnabled, mode != .off else { return }
        Haptics.tap()
        let home = paneIndex.map(FisheyePose.quadDefault) ?? FisheyePose()
        applyPose(home, to: renderer)
        savePose()
    }

    private func savePose() {
        guard interactive, let renderer else { return }
        store.savePose(camera.name, pane: paneIndex, pose: FisheyePose(
            pan: renderer.uniforms.pan,
            tilt: renderer.uniforms.tilt,
            zoom: renderer.uniforms.zoom,
            mode: renderer.uniforms.mode
        ))
    }

    private func apply(config: FisheyeConfig, to renderer: DewarpRenderer?) {
        renderer?.uniforms.centerX = config.centerX
        renderer?.uniforms.centerY = config.centerY
        renderer?.uniforms.radius = config.radius
        renderer?.uniforms.lensFOV = config.lensFOV
    }
}

// MARK: - Quad view (Verkada-style multi-view)

/// One fisheye split into four independently aimed virtual-PTZ panes — each pane has
/// its own renderer, gestures, and saved pose, all fed by the SAME full-res stream
/// (an AVPlayerItem happily serves multiple video outputs).
struct FisheyeQuadView: View {
    let player: AVPlayer
    let camera: FrigateCamera
    var onSingleTap: (() -> Void)? = nil

    /// ONE frame tap shared by all four panes — four separate outputs on one item starve
    /// on device (that was the frozen-pane bug). Created before the panes render.
    @StateObject private var source: FisheyeFrameSource

    init(player: AVPlayer, camera: FrigateCamera, onSingleTap: (() -> Void)? = nil) {
        self.player = player
        self.camera = camera
        self.onSingleTap = onSingleTap
        _source = StateObject(wrappedValue: FisheyeFrameSource(player: player))
    }

    var body: some View {
        GeometryReader { geo in
            let w = (geo.size.width - 2) / 2
            let h = (geo.size.height - 2) / 2
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    pane(0, width: w, height: h)
                    pane(1, width: w, height: h)
                }
                HStack(spacing: 2) {
                    pane(2, width: w, height: h)
                    pane(3, width: w, height: h)
                }
            }
        }
        .background(Color.black)
        .onChange(of: player) { _, newPlayer in source.player = newPlayer }
        .onDisappear { source.stop() }
        .accessibilityLabel("Quad fisheye view — four independent camera angles. Drag any pane to aim it.")
    }

    private func pane(_ index: Int, width: CGFloat, height: CGFloat) -> some View {
        FisheyeDewarpView(
            player: player,
            camera: camera,
            mode: .ptz,
            paneIndex: index,
            sharedSource: source,
            onSingleTap: onSingleTap
        )
        .frame(width: width, height: height)
        .clipped()
    }
}

// MARK: - Live calibration sheet

/// Lens calibration tuned live over the dewarped video: a correctly calibrated lens
/// shows straight walls as straight lines. Values persist per camera via FisheyeStore.
struct FisheyeCalibrationSheet: View {
    let camera: FrigateCamera

    @ObservedObject private var store = FisheyeStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var config = FisheyeConfig()

    var body: some View {
        VStack(spacing: GlassTheme.Space.m) {
            HStack {
                Text("Lens Calibration")
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundStyle(GlassTheme.primary)
                Spacer()
                Button("Reset") {
                    Haptics.tap()
                    config = FisheyeConfig()
                    store.update(camera.name, config: config)
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(GlassTheme.accent)
                Button {
                    Haptics.tap()
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(GlassTheme.secondary)
                }
                .accessibilityLabel("Close calibration")
            }

            Text("Adjust until straight lines in the room look straight.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(GlassTheme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            calibrationSlider("Lens FOV", value: $config.lensFOV, range: 2.6...3.85,
                              display: "\(Int(config.lensFOV * 180 / .pi))°")
            calibrationSlider("Center X", value: $config.centerX, range: 0.3...0.7,
                              display: String(format: "%.2f", config.centerX))
            calibrationSlider("Center Y", value: $config.centerY, range: 0.3...0.7,
                              display: String(format: "%.2f", config.centerY))
            calibrationSlider("Circle size", value: $config.radius, range: 0.3...0.7,
                              display: String(format: "%.2f", config.radius))
        }
        .padding(GlassTheme.Space.l)
        .onAppear { config = store.config(for: camera.name) }
        .onChange(of: config) { _, newConfig in
            // Live-apply while scrubbing — the viewer under the sheet updates in real time.
            store.update(camera.name, config: newConfig)
        }
    }

    private func calibrationSlider(
        _ title: String, value: Binding<Float>, range: ClosedRange<Float>, display: String
    ) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(GlassTheme.primary)
                Spacer()
                Text(display)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(GlassTheme.secondary)
            }
            Slider(value: value, in: range)
                .tint(GlassTheme.accent)
        }
    }
}
