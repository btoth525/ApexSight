import SwiftUI
import AVFoundation

/// Full-screen, landscape-capable zoomable media viewer. Hosts either a live/clip `AVPlayer`
/// or a remote image using the smooth native UIScrollView zoom engine, so users can pinch
/// and double-tap to inspect a face, plate, or detail across the entire phone screen.
///
/// Rotating the phone fills the width — ideal for the wide doorbell / driveway cameras whose
/// letterboxed strip is tiny inside the detail card.
struct FullscreenMediaView: View {
    enum Media: Equatable {
        case player(AVPlayer)
        case image(URL)
        /// A tracked snapshot: the frame plus the object's movement tail (and, when a beat is
        /// selected, its box) — so maximizing the Tracking tab still shows the path, and it all
        /// pinch-zooms together with the image.
        case tracked(url: URL, points: [PathPoint], snapshotTS: Double?, highlightTS: Double?, box: CGRect?, label: String?, score: Double?)

        static func == (lhs: Media, rhs: Media) -> Bool {
            switch (lhs, rhs) {
            case let (.player(a), .player(b)): return a === b
            case let (.image(a), .image(b)): return a == b
            case let (.tracked(u1, _, _, h1, b1, _, _), .tracked(u2, _, _, h2, b2, _, _)): return u1 == u2 && h1 == h2 && b1 == b2
            default: return false
            }
        }
    }

    let media: Media
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                switch media {
                case .player(let player):
                    ZoomableScrollView { VideoLayerView(player: player) }
                case .image(let url):
                    ZoomableScrollView { RemoteImage(url: url, contentMode: .fit) }
                case let .tracked(url, points, snapshotTS, highlightTS, box, label, score):
                    ZoomableScrollView {
                        TrackedSnapshot(url: url) { size in
                            ZStack {
                                PathTailCanvas(points: points, snapshotTS: snapshotTS,
                                               highlightTS: highlightTS, size: size)
                                if let box { BeatBoxView(box: box, size: size, label: label, score: score) }
                            }
                        }
                    }
                }
            }
            .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 42, height: 42)
                            .liquidGlass(in: Circle(), interactive: true, fallbackMaterial: .ultraThinMaterial)
                            .foregroundStyle(.white)
                            .hitTarget()
                            .accessibilityLabel("Close")
                    }
                }
                Spacer()
                Text("Pinch · double-tap to zoom · rotate to fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, GlassTheme.Space.xl)
            .padding(.top, GlassTheme.Space.s)
            .padding(.bottom, GlassTheme.Space.xxl)
        }
        .statusBarHidden(true)
        .onAppear { AppOrientation.enableLandscape() }     // "rotate to fill" — allow landscape here
        .onDisappear { AppOrientation.lockPortrait() }
    }
}

// MARK: - Reusable expand affordance

/// Adds a top-trailing "expand" button over any media view that opens `FullscreenMediaView`.
/// Used across Review, Events, and Timeline so every video/snapshot can be inspected
/// full-screen with the same smooth zoom. Pass `nil` to hide the button (e.g. while loading).
struct ExpandableMediaModifier: ViewModifier {
    let media: FullscreenMediaView.Media?
    /// Optional externally-owned presentation state. Hosts that share an AVPlayer with the
    /// cover pass this so their `onDisappear` (which fires when a fullScreenCover presents!)
    /// can tell "covered by our own viewer" apart from "actually left the screen" — and not
    /// stop the very player the cover is displaying.
    var isPresented: Binding<Bool>? = nil
    // The fullscreen cover hosts RemoteImage (for the .image case), which needs appState
    // to load via appState.client. Cover content doesn't reliably inherit the presenter's
    // environment objects, so capture and re-inject it here.
    @EnvironmentObject private var appState: AppState
    @State private var internalPresented = false

    private var presented: Binding<Bool> { isPresented ?? $internalPresented }

    func body(content: Content) -> some View {
        content
            // Tap anywhere on the media to open it full-screen (not just the corner button) —
            // the whole snapshot/clip is the target, so it's obvious and easy while glancing.
            .contentShape(Rectangle())
            .onTapGesture { if media != nil { presented.wrappedValue = true } }
            .overlay(alignment: .topTrailing) {
                if media != nil {
                    Button { presented.wrappedValue = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .liquidGlass(in: Circle(), interactive: true, fallbackMaterial: .ultraThinMaterial)
                            .foregroundStyle(.white)
                            .hitTarget()
                            .accessibilityLabel("View full screen")
                    }
                    .accessibilityLabel("View full screen")
                    .padding(GlassTheme.Space.s)
                }
            }
            .fullScreenCover(isPresented: presented) {
                if let media {
                    FullscreenMediaView(media: media)
                        .environmentObject(appState)
                }
            }
    }
}

extension View {
    /// Overlays a fullscreen-expand button that opens a zoomable, landscape-capable viewer.
    /// Pass `isPresented` when the host must know the cover is up (e.g. to keep a shared
    /// AVPlayer alive through its own `onDisappear`).
    func expandableMedia(_ media: FullscreenMediaView.Media?, isPresented: Binding<Bool>? = nil) -> some View {
        modifier(ExpandableMediaModifier(media: media, isPresented: isPresented))
    }
}
