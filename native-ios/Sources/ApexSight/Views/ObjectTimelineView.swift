import SwiftUI

/// The tracked object's lifecycle as a modern vertical rail (Frigate shows a plain list). Each beat
/// is a glass row with an object-state icon, a plain-language label, and a chip strip
/// (score / zone / area / ratio / time). Tapping a beat highlights that moment on the hero tail.
struct ObjectTimelineView: View {
    let beats: [TimelineBeat]
    let eventStart: Double?
    @Binding var highlightTS: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(beats.enumerated()), id: \.element.id) { idx, beat in
                row(beat, isFirst: idx == 0, isLast: idx == beats.count - 1)
            }
        }
    }

    private func row(_ beat: TimelineBeat, isFirst: Bool, isLast: Bool) -> some View {
        let s = style(for: beat)
        let selected = highlightTS.map { abs($0 - beat.ts) < 0.001 } ?? false
        return HStack(alignment: .top, spacing: GlassTheme.Space.m) {
            // Left gutter: rail line + node.
            VStack(spacing: 0) {
                Rectangle().fill(GlassTheme.accent.opacity(isFirst ? 0 : 0.25)).frame(width: 2, height: 10)
                ZStack {
                    Circle().fill(s.tint.opacity(0.18)).frame(width: 26, height: 26)
                    Image(systemName: s.icon).font(.system(size: 12, weight: .bold)).foregroundStyle(s.tint)
                }
                Rectangle().fill(GlassTheme.accent.opacity(isLast ? 0 : 0.25)).frame(width: 2).frame(maxHeight: .infinity)
            }
            .frame(width: 26)

            VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
                Text(s.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GlassTheme.primary)
                chips(beat)
            }
            .padding(GlassTheme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GlassTheme.surface.opacity(selected ? 1 : 0.6),
                        in: RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous)
                .stroke(selected ? s.tint.opacity(0.6) : GlassTheme.separator, lineWidth: 1))
            .padding(.vertical, 4)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.select()
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                highlightTS = (selected ? nil : beat.ts)
            }
        }
    }

    @ViewBuilder
    private func chips(_ beat: TimelineBeat) -> some View {
        HStack(spacing: GlassTheme.Space.xs) {
            if let sc = beat.score {
                chip("\(Int((sc * 100).rounded()))%", tint: scoreTint(sc))
            }
            if beat.classType == "entered_zone", let z = beat.zones?.first {
                chip("▣ \(titleize(z))", tint: GlassTheme.teal)
            }
            if let b = beat.box {
                chip(String(format: "area %.1f%%", b.width * b.height * 100), tint: GlassTheme.secondary)
                if b.height > 0 { chip(String(format: "ratio %.2f", b.width / b.height), tint: GlassTheme.secondary) }
            }
            if let start = eventStart {
                chip(relTime(beat.ts - start), tint: GlassTheme.tertiary)
            }
        }
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold)).monospacedDigit()
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(GlassTheme.surfaceHigh, in: Capsule())
    }

    private func scoreTint(_ s: Double) -> Color { s >= 0.85 ? GlassTheme.green : (s >= 0.60 ? GlassTheme.accent : GlassTheme.orange) }
    private func relTime(_ dt: Double) -> String {
        dt < 60 ? String(format: "+%.1fs", max(0, dt)) : "+\(Int(dt) / 60)m \(Int(dt) % 60)s"
    }

    private func style(for beat: TimelineBeat) -> (icon: String, label: String, tint: Color) {
        switch beat.classType {
        case "visible":       return ("eye.fill", "Detected", GlassTheme.accent)
        case "entered_zone":  return ("mappin.and.ellipse", "Entered \(titleize(beat.zones?.first ?? "zone"))", GlassTheme.teal)
        case "attribute":     return ("sparkles", "Recognized \(titleize(beat.attribute ?? "attribute"))", GlassTheme.purple)
        case "sub_label":     return ("person.text.rectangle", "Identified as \(titleize(beat.subLabel ?? "subject"))", GlassTheme.purple)
        case "active":        return ("figure.walk.motion", "Started moving", GlassTheme.green)
        case "stationary":    return ("parkingsign.circle", "Stopped", GlassTheme.orange)
        case "gone", "lost":  return ("arrow.up.forward", "Left frame", GlassTheme.secondary)
        case "heard":         return ("waveform", "Heard audio", GlassTheme.cyan)
        default:              return ("circle.fill", titleize(beat.classType), GlassTheme.secondary)
        }
    }
}
