import SwiftUI

/// Real-time bounding box overlay driven by WebSocket event data. Each box is drawn
/// at the normalized (0-1) coordinates from Frigate's `after.box` field, scaled to
/// the view's actual size. Boxes disappear automatically when Frigate sends an `end`
/// event — no manual cleanup needed.
struct DetectionOverlayView: View {
    let detections: [LiveDetection]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                ForEach(detections) { det in
                    let rect = CGRect(
                        x: det.normBox.minX * size.width,
                        y: det.normBox.minY * size.height,
                        width: det.normBox.width * size.width,
                        height: det.normBox.height * size.height
                    )
                    BoxAnnotation(label: det.label, rect: rect)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: detections.map(\.id))
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
