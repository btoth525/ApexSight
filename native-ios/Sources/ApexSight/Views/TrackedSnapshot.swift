import SwiftUI
import UIKit

/// Aspect-fit geometry from an image's TRUE pixel size — the fix for the old overlay bug, which
/// used Frigate's *declared* camera aspect and drew into the letterbox bars.
enum Letterbox {
    static func fittedRect(imageSize s: CGSize, in c: CGSize) -> CGRect {
        guard s.width > 0, s.height > 0, c.width > 0, c.height > 0 else { return .zero }
        let ia = s.width / s.height, ca = c.width / c.height
        if ia > ca { let h = c.width / ia;  return CGRect(x: 0, y: (c.height - h) / 2, width: c.width, height: h) }
        else       { let w = c.height * ia; return CGRect(x: (c.width - w) / 2, y: 0, width: w, height: c.height) }
    }
}

/// Shows a snapshot aspect-fit and frames image+overlay to the *fitted rect*, so the overlay is
/// proposed EXACTLY the image rect — a normalized point maps with `n * size`, ZERO offset, and can
/// never drift into a black bar. Decodes its own UIImage (RemoteImage hides the pixel size).
struct TrackedSnapshot<Overlay: View>: View {
    let url: URL
    @ViewBuilder var overlay: (_ size: CGSize) -> Overlay
    @EnvironmentObject private var appState: AppState
    @State private var uiImage: UIImage?
    @State private var failed = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = uiImage {
                    let r = Letterbox.fittedRect(imageSize: img.size, in: geo.size)
                    ZStack {
                        Image(uiImage: img).resizable().interpolation(.high)
                        overlay(r.size).allowsHitTesting(false)
                    }
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                } else if failed {
                    Image(systemName: "photo").font(.title).foregroundStyle(GlassTheme.secondary)
                } else {
                    ProgressView().tint(GlassTheme.accent)
                }
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        failed = false
        if let cached = ImageCache.shared.image(for: url) { uiImage = cached; return }
        guard let client = appState.client else { failed = (uiImage == nil); return }
        do {
            let data = try await client.imageData(from: url)
            let decoded = await Task.detached(priority: .utility) { RemoteImage.downsample(data, maxPixel: 1600) }.value
            if let decoded { ImageCache.shared.insert(decoded, for: url); uiImage = decoded } else { failed = (uiImage == nil) }
        } catch { failed = (uiImage == nil) }
    }
}


// MARK: - Consistent media sizing

extension View {
    /// A big, crisp box for the cropped best-shot: the subject fills a generous fixed height at
    /// its OWN aspect (not the ultra-wide camera frame), so the snapshot reads large and clear.
    func snapshotFrame() -> some View {
        self.frame(height: 360).frame(maxWidth: .infinity)
    }

    /// Sizes the full-frame Tracking/History surface to the camera's TRUE aspect (full width,
    /// height = width / aspect) so ultra-wide / fisheye feeds fill edge-to-edge with NO letterbox
    /// bars, capped so a portrait feed can't dominate the screen — and the tail maps 1:1.
    func mediaAspectFrame(_ aspect: CGFloat) -> some View {
        // A Color.clear establishes the aspect box; the media rides in its overlay so it's
        // handed a CONCRETE size. Applying `.aspectRatio` straight onto the media collapses
        // a GeometryReader-based view (TrackedSnapshot) to zero height — a black tab.
        Color.clear
            .aspectRatio(aspect > 0 ? aspect : 16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: 360)
            .overlay { self }
            .clipped()
    }
}
