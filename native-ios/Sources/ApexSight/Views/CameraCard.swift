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
            ZStack(alignment: .bottomLeading) {
                // Fast auto-refreshing still — NOT a live stream per tile. Running a WebRTC
                // connection in every card at once was choppy and fought the full-screen
                // stream for the same camera. The grid stays smooth; tapping opens the single
                // instant live stream (LiveStreamView).
                CameraSnapshotView(
                    camera: camera,
                    onFrame: { hasFrame in
                        withAnimation(.easeIn(duration: 0.3)) { isLive = hasFrame }
                    }
                )

                // Cinematic legibility gradient — clear at top, dark at the bottom so the
                // camera name reads cleanly right on the video (pro-NVR look).
                LinearGradient(
                    colors: [.clear, .clear, .black.opacity(0.8)],
                    startPoint: .top, endPoint: .bottom
                )
                .allowsHitTesting(false)

                nameRow
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
            .overlay(alignment: .topTrailing) {
                capabilityChips.padding(10)
            }
            .cardStroke(GlassTheme.Radius.tile)
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(titleize(camera.name)) camera. Opens live view.")
            .accessibilityAddTraits(.isButton)
        }
        .buttonStyle(.plain)
    }

    private var nameRow: some View {
        HStack(spacing: 7) {
            StatusDot(state: isLive ? .live : .offline)
            Text(titleize(camera.name))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var capabilityChips: some View {
        if let cap = capability {
            HStack(spacing: 5) {
                if cap.hasRecordings { chip("REC", tint: GlassTheme.green) }
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
