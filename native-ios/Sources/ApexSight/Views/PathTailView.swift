import SwiftUI

/// The tracked object's movement trail, drawn on a Canvas aligned to the image rect (`size`), so a
/// normalized point maps with a bare `n * size`. Single hue (accent) — age carried by opacity+width,
/// never color; glow via a wide low-opacity underpass, not `.shadow`. Draws on once (~0.9s ease-out),
/// then stops repainting. Dwell gaps (a parked object) render dashed with a "parked Xm Ys" pill —
/// the biggest free win over Frigate's straight fast-line-across-the-hole.
struct PathTailCanvas: View {
    let snapshotTS: Double?
    var highlightTS: Double? = nil
    let size: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var done = false

    private let pts: [PathPoint]

    init(points: [PathPoint], snapshotTS: Double?, highlightTS: Double? = nil, size: CGSize) {
        self.pts = Self.clean(points)
        self.snapshotTS = snapshotTS
        self.highlightTS = highlightTS
        self.size = size
    }

    var body: some View {
        Group {
            if reduceMotion || done || pts.count < 2 {
                Canvas { ctx, _ in draw(ctx, reveal: pts.count) }
            } else {
                TimelineView(.animation) { tl in
                    Canvas { ctx, _ in
                        let p = min(1, tl.date.timeIntervalSince(start) / 0.9)
                        draw(ctx, reveal: max(1, Int(ceil(Double(pts.count) * easeOut(p)))))
                        if p >= 1 { Task { @MainActor in done = true } }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { start = Date() }
    }

    private func pt(_ p: PathPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
    private func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    static func clean(_ raw: [PathPoint]) -> [PathPoint] {
        var out: [PathPoint] = []
        for p in raw.sorted(by: { $0.ts < $1.ts }) {
            if let last = out.last, hypot(p.x - last.x, p.y - last.y) < 0.006 { continue }
            out.append(p)
        }
        return out
    }

    private func draw(_ ctx: GraphicsContext, reveal: Int) {
        guard size.width > 0, pts.count >= 1 else { return }
        let n = pts.count
        let end = min(max(reveal, 1), n)
        let dur = (pts.last?.ts ?? 0) - (pts.first?.ts ?? 0)
        let gapThresh = max(8.0, 0.15 * dur)
        let accent = GlassTheme.accent

        for i in 1..<max(2, end) where i < end {
            let a = pt(pts[i - 1]), b = pt(pts[i])
            let dt = pts[i].ts - pts[i - 1].ts
            let seg = Path { $0.move(to: a); $0.addLine(to: b) }
            if dt > gapThresh {
                ctx.stroke(seg, with: .color(accent.opacity(0.28)),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [4, 5]))
            } else {
                let frac = Double(i) / Double(max(1, n - 1))
                ctx.stroke(seg, with: .color(accent.opacity(0.16)), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                ctx.stroke(seg, with: .color(accent.opacity(0.35 + 0.65 * frac)),
                           style: StrokeStyle(lineWidth: 1.5 + frac, lineCap: .round))
            }
        }
        // dwell pills at gap vertices
        for i in 1..<max(2, end) where i < end {
            let dt = pts[i].ts - pts[i - 1].ts
            if dt > gapThresh {
                let m = CGPoint(x: (pt(pts[i - 1]).x + pt(pts[i]).x) / 2, y: (pt(pts[i - 1]).y + pt(pts[i]).y) / 2)
                pill(ctx, at: m, text: "parked \(dwell(dt))")
            }
        }
        // best-frame diamond ("this frame")
        if let sts = snapshotTS, let best = pts.prefix(end).min(by: { abs($0.ts - sts) < abs($1.ts - sts) }) {
            diamond(ctx, at: pt(best))
        }
        // tapped-beat highlight ring
        if let hts = highlightTS, let h = pts.prefix(end).min(by: { abs($0.ts - hts) < abs($1.ts - hts) }) {
            let c = pt(h)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20)),
                       with: .color(accent), lineWidth: 2.5)
        }
        // head (latest point)
        if let head = pts.prefix(end).last {
            let c = pt(head)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(accent))
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 7.5, y: c.y - 7.5, width: 15, height: 15)),
                       with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        }
    }

    private func dwell(_ s: Double) -> String {
        let m = Int(s) / 60, sec = Int(s) % 60
        return m > 0 ? "\(m)m \(sec)s" : "\(sec)s"
    }

    private func pill(_ ctx: GraphicsContext, at p: CGPoint, text: String) {
        let resolved = ctx.resolve(Text(text).font(.system(size: 9, weight: .semibold)).foregroundColor(.white))
        let m = resolved.measure(in: CGSize(width: 220, height: 40))
        let rect = CGRect(x: p.x - m.width / 2 - 6, y: p.y - m.height / 2 - 3, width: m.width + 12, height: m.height + 6)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 7), with: .color(GlassTheme.orange.opacity(0.92)))
        ctx.draw(resolved, at: CGPoint(x: rect.midX, y: rect.midY))
    }

    private func diamond(_ ctx: GraphicsContext, at p: CGPoint) {
        let r: CGFloat = 6
        var d = Path()
        d.move(to: CGPoint(x: p.x, y: p.y - r)); d.addLine(to: CGPoint(x: p.x + r, y: p.y))
        d.addLine(to: CGPoint(x: p.x, y: p.y + r)); d.addLine(to: CGPoint(x: p.x - r, y: p.y)); d.closeSubpath()
        ctx.stroke(d, with: .color(.white), lineWidth: 2)
    }
}


/// Verkada-style "lock-on" box for a tapped lifecycle beat: thin corner brackets (not a heavy
/// rectangle) that snap onto the object, a faint body outline, and a tag chip with the label +
/// confidence. Maps with a bare `n * size` onto the same fitted rect the tail uses, so it stays
/// aligned through pinch-zoom.
struct BeatBoxView: View {
    let box: CGRect        // normalized [x, y, w, h] on the full detect frame
    let size: CGSize
    var label: String? = nil
    var score: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var locked = false

    var body: some View {
        let r = CGRect(x: box.minX * size.width, y: box.minY * size.height,
                       width: max(box.width * size.width, 16), height: max(box.height * size.height, 16))
        let bracket = max(min(r.width, r.height) * 0.28, 7)
        let tint = GlassTheme.accent
        ZStack {
            // Faint full-box outline so the whole extent reads; the tag rides its top-left corner
            // (above the edge) so it never covers the subject; the brackets are the hero.
            Rectangle()
                .stroke(tint.opacity(0.30), lineWidth: 1)
                .frame(width: r.width, height: r.height)
                .overlay(alignment: .topLeading) {
                    if let label {
                        Text(tagText(label))
                            .font(.system(size: 10, weight: .heavy)).monospacedDigit()
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(tint, in: Capsule())
                            .fixedSize()
                            .offset(y: -15)
                    }
                }
                .position(x: r.midX, y: r.midY)
            CornerBrackets(len: bracket)
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .shadow(color: tint.opacity(0.75), radius: 5)
        }
        .allowsHitTesting(false)
        .scaleEffect(locked ? 1 : 1.22, anchor: .center)
        .opacity(locked ? 1 : 0)
        .onAppear { withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.62)) { locked = true } }
    }

    private func tagText(_ label: String) -> String {
        guard let score else { return label.uppercased() }
        return "\(label.uppercased())  \(Int((score * 100).rounded()))%"
    }
}

/// Four L-shaped corner brackets inside the given rect — the Verkada "reticle" look.
struct CornerBrackets: Shape {
    var len: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let l = min(len, min(rect.width, rect.height) / 2)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + l)); p.addLine(to: CGPoint(x: rect.minX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))
        p.move(to: CGPoint(x: rect.maxX - l, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - l)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
        p.move(to: CGPoint(x: rect.minX + l, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))
        return p
    }
}
