import SwiftUI

/// Per-camera feature toggles — arm/disarm detect, recordings, snapshots, and audio
/// without touching Frigate's config file. Changes are temporary (survive until Frigate
/// restarts) but instant, which is exactly what "I need to walk past this camera" requires.
struct CameraQuickControlsSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let camera: FrigateCamera

    @State private var state = CameraControlState()
    @State private var isLoading = true
    @State private var toastMessage: String?

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
            .task { await loadState() }
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
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 50)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: toastMessage)
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
                    controlRow(
                        icon: "eye.fill",
                        tint: GlassTheme.green,
                        title: "Detection",
                        subtitle: "Object detection — person, car, animal",
                        isOn: $state.detect
                    ) { enabled in
                        await toggle(label: "Detection \(enabled ? "on" : "off")") {
                            try await appState.client?.setCameraDetect(camera: camera.name, enabled: enabled)
                        }
                    }

                    controlRow(
                        icon: "record.circle.fill",
                        tint: GlassTheme.red,
                        title: "Recordings",
                        subtitle: "Save clips to Frigate storage",
                        isOn: $state.recordings
                    ) { enabled in
                        await toggle(label: "Recordings \(enabled ? "on" : "off")") {
                            try await appState.client?.setCameraRecordings(camera: camera.name, enabled: enabled)
                        }
                    }

                    controlRow(
                        icon: "photo.fill",
                        tint: GlassTheme.blue,
                        title: "Snapshots",
                        subtitle: "Save detection stills to Frigate",
                        isOn: $state.snapshots
                    ) { enabled in
                        await toggle(label: "Snapshots \(enabled ? "on" : "off")") {
                            try await appState.client?.setCameraSnapshots(camera: camera.name, enabled: enabled)
                        }
                    }

                    controlRow(
                        icon: "waveform",
                        tint: GlassTheme.orange,
                        title: "Audio Detection",
                        subtitle: "Detect barking, alarms, breaking glass",
                        isOn: $state.audio
                    ) { enabled in
                        await toggle(label: "Audio \(enabled ? "on" : "off")") {
                            try await appState.client?.setCameraAudio(camera: camera.name, enabled: enabled)
                        }
                    }

                    controlRow(
                        icon: "figure.walk",
                        tint: GlassTheme.cyan,
                        title: "Motion",
                        subtitle: "Pixel-level motion zone trigger",
                        isOn: $state.motion
                    ) { enabled in
                        await toggle(label: "Motion \(enabled ? "on" : "off")") {
                            try await appState.client?.setCameraMotion(camera: camera.name, enabled: enabled)
                        }
                    }
                } header: {
                    Text(titleize(camera.name))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GlassTheme.secondary)
                        .textCase(nil)
                } footer: {
                    Text("These toggles are temporary — they reset when Frigate restarts. Edit config.yml for permanent changes.")
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
        isOn: Binding<Bool>,
        onToggle: @escaping (Bool) async -> Void
    ) -> some View {
        HStack(spacing: GlassTheme.Space.m) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isOn.wrappedValue ? tint : GlassTheme.tertiary)
                .frame(width: 32, height: 32)
                .background((isOn.wrappedValue ? tint : GlassTheme.tertiary).opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GlassTheme.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(GlassTheme.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { isOn.wrappedValue },
                set: { newVal in
                    isOn.wrappedValue = newVal
                    Haptics.tap()
                    Task { await onToggle(newVal) }
                }
            ))
            .labelsHidden()
            .tint(tint)
        }
        .listRowBackground(Color.white.opacity(0.04))
    }

    private func loadState() async {
        isLoading = true
        if let state = try? await appState.client?.cameraControlState(camera: camera.name) {
            self.state = state
        }
        isLoading = false
    }

    private func toggle(label: String, action: @escaping () async throws -> Void) async {
        do {
            try await action()
            showToast(label)
        } catch {
            showToast("Failed — check Frigate connection")
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
