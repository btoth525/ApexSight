import SwiftUI

struct CameraCard: View {
    @EnvironmentObject private var appState: AppState
    let camera: FrigateCamera

    private var capability: CameraCapability? {
        appState.capabilities.first(where: { $0.camera == camera.name })
    }

    var body: some View {
        NavigationLink {
            LiveStreamView(camera: camera)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    if let url = appState.client?.latestFrameURL(camera: camera.name) {
                        RemoteImage(url: url)
                            .frame(height: 170)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }

                    HStack(spacing: 6) {
                        Circle()
                            .fill(.green)
                            .frame(width: 7, height: 7)
                        Text("LIVE")
                            .font(.system(size: 10, weight: .900))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(10)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(titleize(camera.name))
                            .font(.system(size: 16, weight: .900))
                            .foregroundStyle(GlassTheme.primary)
                        capabilityBadges
                    }
                    Spacer()
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .900))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(GlassTheme.blue, in: Circle())
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
                    if cap.hasGo2RtcStream {
                        badge("WebRTC", tint: GlassTheme.blue)
                    }
                    if cap.hasRecordings {
                        badge("Rec", tint: GlassTheme.green)
                    }
                    if cap.hasPtz {
                        badge("PTZ", tint: GlassTheme.orange)
                    }
                }
            }
        } else {
            Text("Latest frame")
                .font(.system(size: 12, weight: .700))
                .foregroundStyle(GlassTheme.secondary)
        }
    }

    private func badge(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .900))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.16), in: Capsule())
    }
}
