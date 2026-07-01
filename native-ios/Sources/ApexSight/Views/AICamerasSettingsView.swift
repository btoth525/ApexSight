import SwiftUI

/// Per-camera on-device AI control. Every camera is enabled by default; the user turns off the
/// ones they don't want analyzed. Feeds `AICameraSettings`.
struct AICamerasSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var disabled: Set<String> = AICameraSettings.disabledCameras

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                    Text("When a camera is on, opening one of its events auto-analyzes the snapshot on your iPhone — who or what is in view, plus any license plate. Turn off cameras you don't want analyzed.")
                        .font(.footnote)
                        .foregroundStyle(GlassTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, GlassTheme.Space.s)

                    if appState.cameras.isEmpty {
                        EmptyStateView(
                            icon: "video.slash",
                            title: "No Cameras",
                            message: "Connect a Frigate server to choose which cameras use AI."
                        )
                    } else {
                        GlassCard {
                            VStack(spacing: GlassTheme.Space.s) {
                                ForEach(Array(appState.cameras.enumerated()), id: \.element.name) { idx, cam in
                                    Toggle(isOn: binding(for: cam.name)) {
                                        Text(titleize(cam.name))
                                            .font(.body)
                                            .foregroundStyle(GlassTheme.primary)
                                    }
                                    .tint(GlassTheme.accent)
                                    if idx < appState.cameras.count - 1 {
                                        Divider().overlay(GlassTheme.separator)
                                    }
                                }
                            }
                        }

                        HStack {
                            Button("Enable All") { setAll(true) }
                            Spacer()
                            Button("Disable All") { setAll(false) }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GlassTheme.accent)
                        .padding(.horizontal, GlassTheme.Space.s)
                    }
                }
                .padding(GlassTheme.Space.l)
            }
        }
        .navigationTitle("AI Cameras")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { !disabled.contains(name) },
            set: { on in
                Haptics.select()
                AICameraSettings.setEnabled(on, for: name)
                disabled = AICameraSettings.disabledCameras
            }
        )
    }

    private func setAll(_ on: Bool) {
        Haptics.tap()
        for cam in appState.cameras { AICameraSettings.setEnabled(on, for: cam.name) }
        disabled = AICameraSettings.disabledCameras
    }
}
