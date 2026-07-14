import SwiftUI

struct CameraCard: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let camera: FrigateCamera

    @State private var isLive = false
    @State private var showSnapshot = false

    private var capability: CameraCapability? {
        appState.capabilities.first(where: { $0.camera == camera.name })
    }

    var body: some View {
        NavigationLink {
            LiveStreamView(camera: camera)
        } label: {
            ZStack(alignment: .bottom) {
                // The wall shows an auto-refreshing snapshot (current frame every few seconds) —
                // instant, reliable, and light — instead of many simultaneous live streams, which
                // spin up slowly and stampede the server. Tapping the tile opens the camera
                // full-quality LIVE (WebRTC) in LiveStreamView. This is the Ring/Nest/UniFi grid
                // model. Letterboxed so ultra-wide cameras show the whole scene.
                LiveSnapshotView(
                    camera: camera,
                    onFrame: { hasFrame in
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { isLive = hasFrame }
                    }
                )

                // Calm "warming up" hint while the tile is still connecting — a soft breathing
                // dot over the cached snapshot, never a spinner. Beats Protect's frozen-frame
                // look: a tile that hasn't gone live yet reads as alive, not stuck.
                if !isLive {
                    ConnectingHint()
                        .transition(.opacity)
                }

                // "Tap to go live" affordance — a frosted play button centered over the snapshot,
                // the way Ring/Nest/Unifi signal a still that opens a live view. Purely decorative
                // (the whole tile is the tap target), so it never intercepts the tap.
                if isLive {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(.white)
                        .offset(x: 1)   // optical-center the triangle in the circle
                        .frame(width: 54, height: 54)
                        .liquidGlass(in: Circle(), fallbackMaterial: .ultraThinMaterial)
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                LinearGradient(
                    colors: [.clear, .clear, .black.opacity(0.8)],
                    startPoint: .top, endPoint: .bottom
                )
                .allowsHitTesting(false)

                bottomBar
            }
            // Size the tile to the camera's true aspect (fisheye/ultra-wide included) so the
            // feed fills its box with no letterbox bars, instead of a forced 16:9.
            .aspectRatio(camera.aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
            .overlay(alignment: .topTrailing) { capabilityChips.padding(11) }
            .cardStroke(GlassTheme.Radius.tile)
            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
            .contentShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(titleize(camera.name)) camera\(isLive ? ", live" : ""). Opens live view.")
            .accessibilityAddTraits(.isButton)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
        // Long-press for a quick big snapshot without leaving the wall — tap still opens live.
        // The explicit preview matters: the default one re-instantiates the whole label —
        // including a second HLS connection to this camera — just for the popup.
        .contextMenu {
            if camera.name != "birdseye", appState.client?.latestFrameURL(camera: camera.name) != nil {
                Button {
                    Haptics.tap()
                    showSnapshot = true
                } label: {
                    Label("View Snapshot", systemImage: "photo")
                }
            }
        } preview: {
            if camera.name != "birdseye", let url = appState.client?.latestFrameURL(camera: camera.name) {
                RemoteImage(url: url, contentMode: .fit)
                    .aspectRatio(camera.aspectRatio, contentMode: .fit)
                    .frame(width: 340)
                    .background(Color.black)
            }
        }
        .fullScreenCover(isPresented: $showSnapshot) {
            if let url = appState.client?.latestFrameURL(camera: camera.name) {
                FullscreenMediaView(media: .image(url))
                    .environmentObject(appState)
            }
        }
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
        .padding(.bottom, GlassTheme.Space.m)
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
