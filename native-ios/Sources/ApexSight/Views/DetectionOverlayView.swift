import SwiftUI

/// Real-time bounding box overlay driven by WebSocket event data. Each box is drawn at the
/// normalized (0-1) coordinates from Frigate's `after.box` field, mapped into the *displayed
/// video rect* — NOT the full container. The video is letterboxed (`.resizeAspect`, the default)
/// or cropped-to-fill (`.resizeAspectFill`), so a naive full-container scale flings boxes into the
/// black bars. Boxes disappear automatically when Frigate sends an `end` event.
struct DetectionOverlayView: View {
    let detections: [LiveDetection]
    /// Native camera aspect ratio (width / height), so the overlay knows where the video is drawn.
    var videoAspect: CGFloat = 16.0 / 9.0
    /// Whether the player is filling (cropping) vs. fitting (letterboxing) — must match the player.
    var fill: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let videoRect = Self.displayedVideoRect(videoAspect: videoAspect, in: geo.size, fill: fill)
            ZStack(alignment: .topLeading) {
                ForEach(detections) { det in
                    let rect = CGRect(
                        x: videoRect.minX + det.normBox.minX * videoRect.width,
                        y: videoRect.minY + det.normBox.minY * videoRect.height,
                        width: det.normBox.width * videoRect.width,
                        height: det.normBox.height * videoRect.height
                    )
                    BoxAnnotation(label: det.label, rect: rect)
                }
            }
            // Fill mode draws the video larger than the container; clip the overflow like the player.
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: detections.map(\.id))
    }

    /// The rectangle the video actually occupies inside `bounds` for the given aspect + gravity.
    /// Fit (letterbox): the video is inscribed, leaving bars. Fill (crop): the video covers `bounds`,
    /// overflowing on one axis (the caller clips).
    static func displayedVideoRect(videoAspect: CGFloat, in bounds: CGSize, fill: Bool) -> CGRect {
        guard bounds.width > 0, bounds.height > 0, videoAspect > 0 else { return .zero }
        let containerAspect = bounds.width / bounds.height
        // Fit: a video wider than the container is limited by width (bars top/bottom).
        // Fill: to cover, a video wider than the container is limited by height (crop sides).
        let widthLimited = fill ? (videoAspect < containerAspect) : (videoAspect > containerAspect)
        let w: CGFloat, h: CGFloat
        if widthLimited {
            w = bounds.width
            h = bounds.width / videoAspect
        } else {
            h = bounds.height
            w = bounds.height * videoAspect
        }
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }
}

private struct BoxAnnotation: View {
    let label: String
    let rect: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Accent-colored stroke box
            Rectangle()
                .strokeBorder(labelColor, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)

            // Label chip in the top-left corner of the box
            Text(label.capitalized)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(labelColor.opacity(0.85), in: Capsule())
                .offset(x: rect.minX + 4, y: rect.minY + 4)
        }
    }

    private var labelColor: Color {
        switch label.lowercased() {
        case "person": return GlassTheme.accent
        case "car", "truck", "bus", "motorcycle": return GlassTheme.orange
        case "dog", "cat", "animal": return GlassTheme.cyan
        case "package", "bicycle": return GlassTheme.blue
        default: return GlassTheme.green
        }
    }
}
