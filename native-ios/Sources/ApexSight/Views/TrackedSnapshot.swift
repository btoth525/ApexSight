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

    /// Aspect-FILL: the image covers the container (overflow clipped), slid so `focus` (normalized
    /// object centre) sits at the container centre — clamped so no edge past the image shows. Lets an
    /// ultra-wide feed be shown BIG, zoomed on the subject, with the overlay still mapping `n * size`.
    static func filledRect(imageSize s: CGSize, in c: CGSize, focus: CGPoint) -> CGRect {
        guard s.width > 0, s.height > 0, c.width > 0, c.height > 0 else { return .zero }
        let ia = s.width / s.height, ca = c.width / c.height
        if ia > ca {
            let w = c.height * ia
            let x = min(0, max(c.width - w, c.width / 2 - focus.x * w))
            return CGRect(x: x, y: 0, width: w, height: c.height)
        } else {
            let h = c.width / ia
            let y = min(0, max(c.height - h, c.height / 2 - focus.y * h))
            return CGRect(x: 0, y: y, width: c.width, height: h)
        }
    }
}

/// Shows a snapshot aspect-fit and frames image+overlay to the *fitted rect*, so the overlay is
/// proposed EXACTLY the image rect — a normalized point maps with `n * size`, ZERO offset, and can
/// never drift into a black bar. Decodes its own UIImage (RemoteImage hides the pixel size).
struct TrackedSnapshot<Overlay: View>: View {
    let url: URL
    /// FILL the container (zoomed on `focus`) instead of aspect-fit — used inline so an ultra-wide
    /// feed is shown big. Fullscreen keeps fit (the whole frame, then pinch-zoom).
    var fill: Bool = false
    /// Normalized object centre the fill zooms toward (ignored when `fill` is false).
    var focus: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @ViewBuilder var overlay: (_ size: CGSize) -> Overlay
    @EnvironmentObject private var appState: AppState
    @State private var uiImage: UIImage?
    @State private var failed = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let img = uiImage {
                    let r = fill ? Letterbox.filledRect(imageSize: img.size, in: geo.size, focus: focus)
                                 : Letterbox.fittedRect(imageSize: img.size, in: geo.size)
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
            .clipped()   // hide the fill overflow
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

    /// Big inline box for the Tracking tab — paired with `TrackedSnapshot(fill:true)` the ultra-wide
    /// frame is shown large and zoomed on the subject instead of a thin letterboxed strip.
    func trackingFrame() -> some View {
        self.frame(height: 280).frame(maxWidth: .infinity)
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
