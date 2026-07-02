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

    func updateUIView(_ view: MTKView, context: Context) {}
}

// MARK: - Fisheye viewer (gestures + renderer lifecycle)

/// The full dewarped-fisheye experience for one camera: owns the renderer, follows the
/// live player across HLS reconnects, and maps drag → pan/tilt, pinch → zoom.
struct FisheyeDewarpView: View {
    let player: AVPlayer
    let camera: FrigateCamera
    let mode: DewarpMode
    /// Single tap toggles the host's immersive chrome, same as the flat player.
    var onSingleTap: (() -> Void)? = nil

    @ObservedObject private var store = FisheyeStore.shared
    @State private var renderer: DewarpRenderer?
    /// Gesture anchors — captured at the first change of each gesture so the whole
    /// drag/pinch is relative to where it started, not cumulative per-event.
    @State private var dragAnchor: (pan: Float, tilt: Float)?
    @State private var zoomAnchor: Float?

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard let renderer, mode != .off else { return }
                if dragAnchor == nil {
                    dragAnchor = (renderer.uniforms.pan, renderer.uniforms.tilt)
                }
                guard let anchor = dragAnchor else { return }
                // Grab-the-scene feel (drag left → content follows left, like Maps/Photos —
                // verified live on the sim; the opposite signs read as inverted joystick).
                // Radians-per-point scales with zoom so dragging tracks the image.
                let s = 0.0045 / max(renderer.uniforms.zoom, 0.4)
                renderer.uniforms.pan = anchor.pan + Float(value.translation.width) * s
                if mode == .ptz {
                    let tilt = anchor.tilt + Float(value.translation.height) * s
                    renderer.uniforms.tilt = min(max(tilt, 0.05), .pi * 0.58)
                }
            }
            .onEnded { _ in dragAnchor = nil }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                guard let renderer, mode != .off else { return }
                if zoomAnchor == nil { zoomAnchor = renderer.uniforms.zoom }
                guard let anchor = zoomAnchor else { return }
                renderer.uniforms.zoom = min(max(anchor * Float(scale), 0.5), 6)
            }
            .onEnded { _ in zoomAnchor = nil }
    }

    var body: some View {
        Group {
            if let renderer {
                MetalDewarpView(renderer: renderer)
                    .gesture(dragGesture.simultaneously(with: pinchGesture))
                    .onTapGesture { onSingleTap?() }
            } else {
                Color.black
            }
        }
        .onAppear {
            let r = DewarpRenderer(player: player)
            apply(config: store.config(for: camera.name), to: r)
            r?.uniforms.mode = mode.rawValue
            renderer = r
        }
        .onChange(of: player) { _, newPlayer in
            // HLS reconnects rebuild the AVPlayer — repoint the frame tap.
            renderer?.player = newPlayer
        }
        .onChange(of: mode) { _, newMode in
            renderer?.uniforms.mode = newMode.rawValue
        }
        .onChange(of: store.configs[camera.name]) { _, _ in
            apply(config: store.config(for: camera.name), to: renderer)
        }
        .accessibilityLabel("Dewarped fisheye view, \(mode.label). Drag to look around, pinch to zoom.")
    }

    private func apply(config: FisheyeConfig, to renderer: DewarpRenderer?) {
        renderer?.uniforms.centerX = config.centerX
        renderer?.uniforms.centerY = config.centerY
        renderer?.uniforms.radius = config.radius
        renderer?.uniforms.lensFOV = config.lensFOV
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
