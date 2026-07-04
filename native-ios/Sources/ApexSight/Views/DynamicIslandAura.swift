import SwiftUI

/// A living glow that traces the Dynamic Island's silhouette and reacts to the cameras in
/// real time: a slow cyan breath when all is calm, amber shimmer on motion, and a red bloom
/// with an outward ripple the instant a person is detected. Purely decorative, non-interactive,
/// pinned to the top of the screen over everything. Reduce Motion → a steady glow, no animation.
///
/// The Dynamic Island is a fixed size on the devices that have one (the 15 Pro / 16 / 17 / Air
/// families), so the capsule geometry is hard-coded; on a device without an Island the glow just
/// reads as a tasteful status light behind the notch/camera area.
struct DynamicIslandAura: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Dynamic Island pill geometry, in points, measured from the very top of the screen.
    private let islandWidth: CGFloat = 126
    private let islandHeight: CGFloat = 37.33
    private let islandTop: CGFloat = 11

    /// Ripple start times (seconds, monotonic) — one per fresh person detection; each expands
    /// and fades over `rippleLife`, then is pruned.
    @State private var ripples: [Double] = []
    @State private var lastAlertCount = 0

    private let rippleLife: Double = 1.7

    private enum Threat {
        case calm, motion, alert
        var color: Color {
            switch self {
            case .calm: return Color(red: 0.30, green: 0.85, blue: 1.0)   // cyan
            case .motion: return GlassTheme.orange
            case .alert: return GlassTheme.red
            }
        }
        /// Peak glow strength.
        var intensity: Double {
            switch self { case .calm: return 0.30; case .motion: return 0.65; case .alert: return 1.0 }
        }
    }

    /// What the cameras are seeing right now, distilled to one level.
    private var threat: Threat {
        #if DEBUG
        if let raw = UserDefaults(suiteName: ApexAppGroup.identifier)?.object(forKey: "apex.debug.aura") as? Int {
            return [0: Threat.calm, 1: .motion, 2: .alert][raw] ?? .calm
        }
        #endif
        let labels = appState.liveDetections.values.flatMap { $0 }.map { $0.label.lowercased() }
        if labels.contains(where: { $0.contains("person") || $0.contains("face") }) { return .alert }
        return labels.isEmpty ? .calm : .motion
    }

    /// Count of person-level detections, to fire a ripple only when a NEW one appears.
    private var alertCount: Int {
        appState.liveDetections.values.flatMap { $0 }
            .filter { $0.label.lowercased().contains("person") }.count
    }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                draw(into: &ctx, size: size, now: now)
            }
            .blur(radius: 14)
            .blendMode(.plusLighter)   // the glow adds light — reads as an emitted halo, not paint
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .onChange(of: alertCount) { old, new in
                // A newly-appeared person blooms a ripple (not on every frame it's present).
                if new > old, !reduceMotion {
                    ripples.append(now)
                    if ripples.count > 4 { ripples.removeFirst(ripples.count - 4) }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(into ctx: inout GraphicsContext, size: CGSize, now: Double) {
        let threat = threat
        let color = threat.color

        // The base capsule that hugs the Island, plus a little bleed so the blur spills around it.
        let bleed: CGFloat = 5
        func islandCapsule(padding p: CGFloat) -> Path {
            let rect = CGRect(
                x: (size.width - islandWidth) / 2 - p,
                y: islandTop - p,
                width: islandWidth + p * 2,
                height: islandHeight + p * 2
            )
            return Path(roundedRect: rect, cornerRadius: (islandHeight + p * 2) / 2)
        }

        // 1) Breathing halo tracing the Island.
        let breath = reduceMotion ? 0.6 : (sin(now * 1.7) * 0.5 + 0.5)          // 0…1
        let haloAlpha = threat.intensity * (0.45 + 0.55 * breath)
        ctx.stroke(
            islandCapsule(padding: bleed),
            with: .color(color.opacity(haloAlpha)),
            lineWidth: 6 + CGFloat(breath) * 4
        )
        // Inner brighter rim for a crisp lit edge.
        ctx.stroke(
            islandCapsule(padding: bleed - 2),
            with: .color(color.opacity(haloAlpha * 0.9)),
            lineWidth: 2.5
        )

        // 2) Motion shimmer — a soft second breath out of phase, so amber "flickers" alive.
        if threat != .calm, !reduceMotion {
            let shimmer = (sin(now * 5.3 + 1.2) * 0.5 + 0.5) * threat.intensity * 0.4
            ctx.stroke(islandCapsule(padding: bleed + 3),
                       with: .color(color.opacity(shimmer)), lineWidth: 3)
        }

        // 3) Alert ripples — expanding, fading capsules pulsing outward from the Island.
        ripples.removeAll { now - $0 > rippleLife }
        for start in ripples {
            let p = (now - start) / rippleLife            // 0…1 progress
            guard p >= 0, p <= 1 else { continue }
            let spread = bleed + CGFloat(p) * 46          // grows outward
            let fade = (1 - p) * (1 - p)                  // ease-out fade
            ctx.stroke(islandCapsule(padding: spread),
                       with: .color(color.opacity(0.9 * fade)),
                       lineWidth: 3.5 * (1 - CGFloat(p)))
        }
    }
}
