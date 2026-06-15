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
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    // HLSLivePlayerView shows its own snapshot placeholder internally,
                    // so there's never a black gap regardless of stream state.
                    HLSLivePlayerView(
                        camera: camera,
                        onPlaying: { playing in
                            withAnimation(.easeIn(duration: 0.3)) { isLive = playing }
                        }
                    )
                    liveBadge
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(titleize(camera.name))
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(GlassTheme.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    capabilityBadges
                }
                .padding(.top, 12)
            }
            .padding(10)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var capabilityBadges: some View {
        if let cap = capability {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    if cap.hasGo2RtcStream { badge("HD", tint: GlassTheme.blue) }
                    if cap.hasRecordings    { badge("Rec", tint: GlassTheme.green) }
                    if cap.hasPtz          { badge("PTZ", tint: GlassTheme.orange) }
                }
            }
        } else {
            Text("Live")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(GlassTheme.secondary)
        }
    }

    private func badge(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.16), in: Capsule())
    }

    private var liveBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isLive ? Color.green : Color.yellow)
                .frame(width: 7, height: 7)
            Text(isLive ? "LIVE" : "…")
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(10)
    }
}
