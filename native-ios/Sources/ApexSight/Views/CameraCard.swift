import AVFoundation
import SwiftUI

struct CameraCard: View {
    @EnvironmentObject private var appState: AppState
    let camera: FrigateCamera

    @State private var player: AVPlayer?
    @State private var isLive = false
    @State private var statusObserver: NSKeyValueObservation?

    private var capability: CameraCapability? {
        appState.capabilities.first(where: { $0.camera == camera.name })
    }

    var body: some View {
        NavigationLink {
            LiveStreamView(camera: camera)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    // Reliable snapshot underneath; live stream overlays once ready.
                    if let url = appState.client?.latestFrameURL(camera: camera.name) {
                        RemoteImage(url: url)
                            .frame(height: 170)
                            .frame(maxWidth: .infinity)
                            .clipped()
                    }
                    if isLive, let player {
                        GridPlayerCell(player: player)
                            .frame(height: 170)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            .transition(.opacity)
                    }
                    liveBadge
                }
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .task { startLive() }
                .onDisappear { stopLive() }

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(titleize(camera.name))
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(GlassTheme.primary)
                        capabilityBadges
                    }
                    Spacer()
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .black))
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
                .fill(isLive ? .green : .yellow)
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

    private func startLive() {
        guard player == nil, let client = appState.client else { return }
        let item = client.playerItem(for: client.liveHLSURL(camera: camera.name))
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = true
        newPlayer.play()
        player = newPlayer
        statusObserver = item.observe(\.status, options: [.new]) { playerItem, _ in
            DispatchQueue.main.async {
                withAnimation(.easeIn(duration: 0.3)) {
                    isLive = (playerItem.status == .readyToPlay)
                }
            }
        }
    }

    private func stopLive() {
        statusObserver = nil
        player?.pause()
        player = nil
        isLive = false
    }
}
