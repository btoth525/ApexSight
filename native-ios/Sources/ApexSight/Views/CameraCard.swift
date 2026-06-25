import SwiftUI

struct CameraCard: View {
    @EnvironmentObject private var appState: AppState
    let camera: FrigateCamera

    @State private var isLive = false

    private var capability: CameraCapability? {
        appState.capabilities.first(where: { $0.camera == camera.name })
    }

    var body: some View {
        NavigationLink {
            LiveStreamView(camera: camera)
        } label: {
            ZStack(alignment: .bottom) {
                // Live, instant WebRTC on the FULL main stream, always on (persistent) for
                // every camera, with the cached snapshot behind so it's never black and
                // letterboxed so ultra-wide cameras show the whole scene.
                LiveVideoPlayerView(
                    camera: camera,
                    persistent: true,
                    onPlaying: { playing in
                        withAnimation(.easeInOut(duration: 0.3)) { isLive = playing }
                    }
                )

                LinearGradient(
                    colors: [.clear, .clear, .black.opacity(0.8)],
                    startPoint: .top, endPoint: .bottom
                )
                .allowsHitTesting(false)

                bottomBar
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
            .overlay(alignment: .topLeading) { liveBadge.padding(11) }
            .overlay(alignment: .topTrailing) { capabilityChips.padding(11) }
            .cardStroke(GlassTheme.Radius.tile)
            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(titleize(camera.name)) camera\(isLive ? ", live" : ""). Opens live view.")
            .accessibilityAddTraits(.isButton)
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Text(titleize(camera.name))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
                .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    /// Broadcast-style LIVE pill once the stream is playing. Nothing is shown while it spins
    /// up — the snapshot is already on screen, so there's no "Connecting" clutter.
    @ViewBuilder
    private var liveBadge: some View {
        if isLive {
            HStack(spacing: 5) {
                Circle().fill(.white).frame(width: 6, height: 6)
                Text("LIVE")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(GlassTheme.red, in: Capsule())
            .transition(.opacity.combined(with: .scale))
        }
    }

    @ViewBuilder
    private var capabilityChips: some View {
        if let cap = capability {
            HStack(spacing: 5) {
                if cap.hasRecordings { chip("REC", tint: GlassTheme.red) }
                if cap.hasPtz { chip("PTZ", tint: GlassTheme.orange) }
            }
        }
    }

    private func chip(_ label: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}
