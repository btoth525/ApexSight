import SwiftUI

/// Per-camera fisheye opt-in. Marking a camera as fisheye gives its full-screen
/// viewer real-time GPU dewarping with virtual PTZ (drag to look around, pinch to
/// zoom), a panorama sweep, and a little-planet view — plus a live lens-calibration
/// sheet. Wall tiles keep showing the raw feed.
struct FisheyeSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var store = FisheyeStore.shared

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                    Text("Turn on for cameras with a fisheye (360°) lens. Their full-screen view opens in Virtual PTZ — drag to look around the room, pinch to zoom — with panorama and little-planet views a tap away. Fine-tune the lens from the sliders button in the viewer.")
                        .font(.footnote)
                        .foregroundStyle(GlassTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, GlassTheme.Space.s)

                    if appState.cameras.isEmpty {
                        EmptyStateView(
                            icon: "video.slash",
                            title: "No Cameras",
                            message: "Connect a Frigate server to choose your fisheye cameras."
                        )
                    } else {
                        GlassCard {
                            VStack(spacing: GlassTheme.Space.s) {
                                ForEach(Array(appState.cameras.enumerated()), id: \.element.name) { idx, cam in
                                    Toggle(isOn: binding(for: cam.name)) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(titleize(cam.name))
                                                .font(.body)
                                                .foregroundStyle(GlassTheme.primary)
                                            if isLikelyFisheye(cam) {
                                                Text("Square sensor — likely fisheye")
                                                    .font(.caption2)
                                                    .foregroundStyle(GlassTheme.accent)
                                            }
                                        }
                                    }
                                    .tint(GlassTheme.accent)
                                    if idx < appState.cameras.count - 1 {
                                        Divider().overlay(GlassTheme.separator)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(GlassTheme.Space.l)
            }
        }
        .navigationTitle("Fisheye Cameras")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
    }

    private func binding(for name: String) -> Binding<Bool> {
        Binding(
            get: { store.isFisheye(name) },
            set: { store.setFisheye(name, enabled: $0) }
        )
    }

    /// A near-square frame is the classic fisheye signature (a circular lens disc on a
    /// square sensor) — surfaced as a hint, never auto-enabled.
    private func isLikelyFisheye(_ camera: FrigateCamera) -> Bool {
        let ratio = camera.aspectRatio
        return ratio > 0.9 && ratio < 1.15
    }
}
