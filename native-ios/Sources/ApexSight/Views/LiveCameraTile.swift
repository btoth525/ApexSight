import SwiftUI

/// A large, modern, LIVE camera tile for the home wall — real WebRTC/HLS video (not a snapshot),
/// on the light `_sub` stream so a wall of them stays smooth on device. In a `LazyVStack` only
/// on-screen tiles decode, so the full camera list streams without stampeding the phone. A cached
/// snapshot sits underneath for an instant paint; the live picture fades in over it. Tapping opens
/// the full-quality single-camera viewer.
struct LiveCameraTile: View {
    // Observe the narrow ImageSession (client + wall inputs), NOT AppState — so a wall of tiles
    // doesn't re-render `body` on every live-detection/event tick during motion.
    @ObservedObject private var session = ImageSession.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let camera: FrigateCamera

    @State private var isLive = false

    private var capability: CameraCapability? {
        session.capabilities[camera.name]
    }

    var body: some View {
        NavigationLink {
            LiveStreamView(camera: camera)
        } label: {
            ZStack(alignment: .bottom) {
                Color.black

                // The instant paint (cached last frame → disk → network, fading out when live
                // pixels land) is the player view's own placeholder. A separate `LiveSnapshotView`
                // used to sit UNDER it — fully covered by the player's opaque background, yet
                // polling `latest.jpg` every 3 s per visible tile, decoding it, and JPEG-encoding
                // it to disk on the main thread. Pixels nobody could ever see.

                // The live feed — sub-second WebRTC (falls back to HLS/MJPEG), muted on the wall.
                HLSLivePlayerView(
                    camera: camera,
                    preferSub: true,
                    persistent: true,
                    onPlaying: { playing in
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { isLive = playing }
                    },
                    muted: true
                )
                .allowsHitTesting(false)

                if !isLive {
                    ConnectingHint().transition(.opacity)
                }

                bottomBar
            }
            .overlay(alignment: .topTrailing) {
                // Signals the tile opens a pinch-to-zoom full-res viewer (Ring/Reolink-style).
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .liquidGlass(in: Circle(), interactive: false, fallbackMaterial: .ultraThinMaterial)
                    .padding(GlassTheme.Space.s)
                    .allowsHitTesting(false)
            }
            .aspectRatio(camera.aspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous))
            // The app-wide top-lit glass edge (was a flat separator hairline) so the hero camera
            // tiles match every other card in the app.
            .cardStroke(GlassTheme.Radius.card)
            .contentShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(titleize(camera.name)) camera\(isLive ? ", live" : ""). Opens live view.")
    }

    private var bottomBar: some View {
        HStack(spacing: GlassTheme.Space.s) {
            // Live / connecting dot.
            Circle()
                .fill(isLive ? GlassTheme.green : GlassTheme.tertiary)
                .frame(width: 8, height: 8)

            Text(titleize(camera.name))
                .font(.headline.weight(.semibold))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(color: .black.opacity(0.5), radius: 4, y: 1)

            Spacer(minLength: 0)

            if capability?.hasRecordings == true {
                Image(systemName: "record.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            if capability?.hasPtz == true {
                Image(systemName: "dpad")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, GlassTheme.Space.m)
        .padding(.vertical, GlassTheme.Space.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
        )
    }
}
