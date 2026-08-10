import SwiftUI

/// Per-camera feature toggles — arm/disarm detect, recordings, snapshots, audio, and motion
/// LIVE. Commands go over Frigate's WebSocket (`<camera>/<feature>/set`), which applies them
/// instantly to the running instance; the HTTP config API only stages the config file and needs
/// a restart (that was the "says it did but it didn't" bug). State is read from the live
/// `<camera>/<feature>/state` topics that `AppState.cameraControlStates` keeps current.
struct CameraQuickControlsSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let camera: FrigateCamera

    /// Only true on the very first open of a camera whose live state hasn't arrived yet.
    @State private var isLoading = false
    @State private var toastMessage: String?

    /// The live state (WS is the source of truth). Falls back to a neutral default until the
    /// retained state arrives — which is usually already present, since the socket is connected
    /// the whole time the app is open.
    private var state: CameraControlState {
        appState.cameraControlStates[camera.name] ?? CameraControlState()
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()
                content
            }
            .navigationTitle("Camera Controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(GlassTheme.accent)
                }
            }
            .task { await seedStateIfNeeded() }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .overlay(alignment: .bottom) {
            if let msg = toastMessage {
                Text(msg)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, GlassTheme.Space.l)
                    .padding(.vertical, GlassTheme.Space.s)
                    .liquidGlass(in: Capsule(), fallbackMaterial: .ultraThinMaterial)
                    .padding(.bottom, 50)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: toastMessage)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .tint(GlassTheme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section {
                    controlRow(icon: "eye.fill", tint: GlassTheme.green, title: "Detection",
                               subtitle: "Object detection — person, car, animal",
                               isOn: state.detect, feature: .detect)
                    controlRow(icon: "record.circle.fill", tint: GlassTheme.red, title: "Recordings",
                               subtitle: "Save clips to Frigate storage",
                               isOn: state.recordings, feature: .recordings)
                    controlRow(icon: "photo.fill", tint: GlassTheme.blue, title: "Snapshots",
                               subtitle: "Save detection stills to Frigate",
                               isOn: state.snapshots, feature: .snapshots)
                    controlRow(icon: "waveform", tint: GlassTheme.orange, title: "Audio Detection",
                               subtitle: "Detect barking, alarms, breaking glass",
                               isOn: state.audio, feature: .audio)
                    controlRow(icon: "figure.walk", tint: GlassTheme.cyan, title: "Motion",
                               subtitle: "Pixel-level motion zone trigger",
                               isOn: state.motion, feature: .motion)
                } header: {
                    Text(titleize(camera.name))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GlassTheme.secondary)
                        .textCase(nil)
                } footer: {
                    Text("Live camera controls. Changes apply instantly and reset when Frigate restarts (edit config.yml for permanent changes).")
                        .font(.caption)
                        .foregroundStyle(GlassTheme.tertiary)
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func controlRow(
        icon: String,
        tint: Color,
        title: String,
        subtitle: String,
        isOn: Bool,
        feature: CameraFeature
    ) -> some View {
        HStack(spacing: GlassTheme.Space.m) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isOn ? tint : GlassTheme.tertiary)
                .frame(width: 32, height: 32)
                .background((isOn ? tint : GlassTheme.tertiary).opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GlassTheme.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(GlassTheme.secondary)
            }

            Spacer()

            // Title as the (visually hidden) toggle label so VoiceOver announces e.g.
            // "Detection, switch, on" instead of a bare "switch"; subtitle becomes the hint.
            // The command goes over the WebSocket; `setCameraControl` reports whether it reached
            // a live socket and only then records the new state, so a send dropped during a
            // reconnect backoff springs the toggle back instead of confirming a change Frigate
            // never received.
            Toggle(title, isOn: Binding(
                get: { isOn },
                set: { newVal in
                    Haptics.tap()
                    let applied = appState.setCameraControl(camera: camera.name, feature: feature, enabled: newVal)
                    if applied {
                        showToast("\(title) \(newVal ? "on" : "off")")
                    } else {
                        Haptics.warning()
                        showToast("Not connected to Frigate — \(title.lowercased()) unchanged")
                    }
                }
            ))
            .labelsHidden()
            .tint(tint)
            .accessibilityHint(subtitle)
        }
        .listRowBackground(Color.white.opacity(0.04))
    }

    /// Seed the live state map for this camera if the WS hasn't delivered it yet, using the
    /// config file as a first approximation. Once a `<camera>/<feature>/state` message arrives
    /// it overrides this. Usually the map is already populated (socket connected on launch).
    private func seedStateIfNeeded() async {
        guard appState.cameraControlStates[camera.name] == nil else { return }
        if let seed = try? await appState.client?.cameraControlState(camera: camera.name),
           appState.cameraControlStates[camera.name] == nil {
            appState.cameraControlStates[camera.name] = seed
        }
    }

    private func showToast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            toastMessage = nil
        }
    }
}
