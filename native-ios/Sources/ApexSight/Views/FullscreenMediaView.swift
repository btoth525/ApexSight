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

        static func == (lhs: Media, rhs: Media) -> Bool {
            switch (lhs, rhs) {
            case let (.player(a), .player(b)): return a === b
            case let (.image(a), .image(b)): return a == b
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
                }
            }
            .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .black))
                            .frame(width: 42, height: 42)
                            .background(.ultraThinMaterial, in: Circle())
                            .foregroundStyle(.white)
                    }
                }
                Spacer()
                Text("Pinch · double-tap to zoom · rotate to fill")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 22)
        }
        .statusBarHidden(true)
    }
}

// MARK: - Reusable expand affordance

/// Adds a top-trailing "expand" button over any media view that opens `FullscreenMediaView`.
/// Used across Review, Events, and Timeline so every video/snapshot can be inspected
/// full-screen with the same smooth zoom. Pass `nil` to hide the button (e.g. while loading).
struct ExpandableMediaModifier: ViewModifier {
    let media: FullscreenMediaView.Media?
    @State private var showFullscreen = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if media != nil {
                    Button { showFullscreen = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .black))
                            .frame(width: 34, height: 34)
                            .background(.ultraThinMaterial, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .padding(8)
                }
            }
            .fullScreenCover(isPresented: $showFullscreen) {
                if let media {
                    FullscreenMediaView(media: media)
                }
            }
    }
}

extension View {
    /// Overlays a fullscreen-expand button that opens a zoomable, landscape-capable viewer.
    func expandableMedia(_ media: FullscreenMediaView.Media?) -> some View {
        modifier(ExpandableMediaModifier(media: media))
    }
}
