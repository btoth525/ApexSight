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
                    Text("For cameras that are on: opening an event auto-analyzes the snapshot on your iPhone (who/what is in view, plus any plate), and — once Frigate writes its AI description — your notification updates with it, HomeKit-style. Turn off any camera you don't want AI on.")
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
        // Reconcile the current choice to the relay whenever the page opens.
        .onAppear { syncToRelay() }
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { !disabled.contains(name) },
            set: { on in
                Haptics.select()
                AICameraSettings.setEnabled(on, for: name)
                disabled = AICameraSettings.disabledCameras
                syncToRelay()
            }
        )
    }

    private func setAll(_ on: Bool) {
        Haptics.tap()
        for cam in appState.cameras { AICameraSettings.setEnabled(on, for: cam.name) }
        disabled = AICameraSettings.disabledCameras
        syncToRelay()
    }

    /// Push the per-camera choice to the relay so AI-description notification follow-ups honor it
    /// even when the app is closed. Fire-and-forget; harmless if the relay/pairing isn't set up.
    private func syncToRelay() {
        let relayURL = DeviceTokenStore.relayURL
        let pairing = DeviceTokenStore.ensurePairingCode()
        guard !relayURL.isEmpty, !pairing.isEmpty else { return }
        let disabledList = Array(AICameraSettings.disabledCameras)
        Task { try? await RelayClient.syncAICameras(relayURL: relayURL, pairingCode: pairing, disabled: disabledList) }
    }
}
