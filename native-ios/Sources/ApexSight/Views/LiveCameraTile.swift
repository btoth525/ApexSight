import SwiftUI

/// A large, modern, LIVE camera tile for the home wall — real WebRTC/HLS video (not a snapshot),
/// on the light `_sub` stream so a wall of them stays smooth on device. In a `LazyVStack` only
/// on-screen tiles decode, so the full camera list streams without stampeding the phone. A cached
/// snapshot sits underneath for an instant paint; the live picture fades in over it. Tapping opens
/// the full-quality single-camera viewer.
struct LiveCameraTile: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                Color.black

                // Instant paint: the camera's cached last frame, covered the moment live paints.
                LiveSnapshotView(camera: camera)
                    .opacity(isLive ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: isLive)

                // The live feed — sub-second WebRTC (falls back to HLS/MJPEG), muted on the wall.
                HLSLivePlayerView(
                    camera: camera,
                    preferSub: true,
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
            .aspectRatio(16.0 / 9.0, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous)
                    .stroke(GlassTheme.separator, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
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
                .shadow(color: isLive ? GlassTheme.green.opacity(0.8) : .clear, radius: 4)

            Text(titleize(camera.name))
                .font(.system(size: 17, weight: .semibold))
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
