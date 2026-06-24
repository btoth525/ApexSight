import SwiftUI

struct CameraCard: View {
    @EnvironmentObject private var appState: AppState
    let camera: FrigateCamera

    @State private var isLive = false
    @StateObject private var pip = LivePiPController()

    private var capability: CameraCapability? {
        appState.capabilities.first(where: { $0.camera == camera.name })
    }

    var body: some View {
        NavigationLink {
            LiveStreamView(camera: camera)
        } label: {
            ZStack(alignment: .bottomLeading) {
                // HLSLivePlayerView shows its own snapshot placeholder internally, so
                // there's never a black gap. PiP wired so long-press can float it.
                HLSLivePlayerView(
                    camera: camera,
                    persistent: true,
                    pipController: pip,
                    onPlaying: { playing in
                        withAnimation(.easeIn(duration: 0.3)) { isLive = playing }
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
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(alignment: .topTrailing) {
                capabilityChips.padding(10)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if pip.isSupported {
                Button {
                    Haptics.tap()
                    pip.toggle()
                } label: {
                    Label(pip.isActive ? "Exit Picture in Picture" : "Picture in Picture",
                          systemImage: pip.isActive ? "pip.exit" : "pip.enter")
                }
            }
        }
    }

    private var nameRow: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(isLive ? Color.green : Color.yellow)
                .frame(width: 7, height: 7)
                .shadow(color: (isLive ? Color.green : Color.yellow).opacity(0.8), radius: 3)
            Text(titleize(camera.name))
                .font(.system(size: 15, weight: .black))
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
        Text(label)
            .font(.system(size: 9, weight: .black))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.85), in: Capsule())
    }
}
