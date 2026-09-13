import SwiftUI

/// The scrolling ruler under the video: motion heat, recording coverage, colour-coded event
/// bars, adaptive tick labels, and a fixed centre playhead. Drag to scrub (with a flick that
/// coasts), pinch to zoom, tap to jump.
///
/// Everything is drawn in one `Canvas` from the engine's `center` + `visibleSeconds`, so a pan is
/// a single redraw of the visible window — there is no scroll view to fight and no per-event view
/// to lay out, which is what keeps a day with 500 detections smooth at 60 fps.
struct TimelineRuler: View {
    @ObservedObject var engine: TimelineEngine
    let events: [FrigateEvent]
    let motion: [FrigateClient.MotionSample]
    /// Merged recording coverage — gaps between ranges are honest "no footage here".
    let coverage: [ClosedRange<Double>]
    /// Fires once the finger lifts (after any coast) with the settled time.
    let onScrubEnd: (Double) -> Void
    let onTapEvent: (FrigateEvent) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var dragStartCenter: Double?
    @State private var pinchStartVisible: Double?
    @State private var coastTask: Task<Void, Never>?
    @State private var lastHapticEventID: String?
    @State private var lastHapticHour: Int?
    @State private var hitEdge = false
    @State private var hitZoomLimit = false
    /// Lane per event id, assigned once over the WHOLE list so a pan never reshuffles pills.
    @State private var lanes: [String: Int] = [:]

    // MARK: Layout constants

    private static let laneCount = 3
    private static let labelBand: CGFloat = 16
    private static let eventTop: CGFloat = 36
    private static let laneHeight: CGFloat = 9
    private static let motionMax: CGFloat = 26
    private static let bottomInset: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let height = geo.size.height
            let spp = engine.visibleSeconds / Double(width)
            let left = engine.center - Double(width) / 2 * spp

            ZStack(alignment: .bottomTrailing) {
                Canvas(rendersAsynchronously: false) { ctx, size in
                    draw(ctx: ctx, size: size, left: left, spp: spp)
                }
                playhead(height: height)
                    .frame(maxWidth: .infinity, alignment: .center)
                zoomChip
            }
            .background(GlassTheme.surface.opacity(0.55))
            .contentShape(Rectangle())
            .onTapGesture { location in tapped(at: location, left: left, spp: spp) }
            .gesture(drag(spp: spp))
            .simultaneousGesture(pinch())
            .accessibilityElement()
            .accessibilityLabel("Recording timeline")
            .accessibilityValue(Date(timeIntervalSince1970: engine.center)
                .formatted(date: .abbreviated, time: .standard))
            .accessibilityHint("Swipe up or down to move through the recording")
            .accessibilityAdjustableAction { direction in
                let step = engine.visibleSeconds / 10
                switch direction {
                case .increment: engine.center = engine.clamped(engine.center + step)
                case .decrement: engine.center = engine.clamped(engine.center - step)
                @unknown default: break
                }
                onScrubEnd(engine.center)
            }
        }
        .onAppear { assignLanes() }
        .onChange(of: events) { _, _ in assignLanes() }
        .onDisappear { coastTask?.cancel() }
    }

    // MARK: - Drawing

    private func draw(ctx: GraphicsContext, size: CGSize, left: Double, spp: Double) {
        let right = left + Double(size.width) * spp
        let now = engine.latest
        func x(_ t: Double) -> CGFloat { CGFloat((t - left) / spp) }

        // Motion heat — the "where did things happen" glance, drawn first so everything sits on it.
        if motion.count > 1 {
            let bucket = max(60, motion[1].startTime - motion[0].startTime)
            let base = size.height - Self.bottomInset
            for sample in motion where sample.startTime + bucket >= left && sample.startTime <= right {
                let level = max(0, min(1, sample.motion / 100))
                guard level > 0.02 else { continue }
                let x0 = x(sample.startTime), x1 = x(sample.startTime + bucket)
                let h = 3 + Self.motionMax * CGFloat(level)
                let rect = CGRect(x: x0, y: base - h, width: max(1, x1 - x0 - 0.5), height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                         with: .color(GlassTheme.accent.opacity(0.10 + 0.32 * level)))
            }
        }

        // Recording coverage — a thin strip; where it's missing there is genuinely nothing to play.
        for range in coverage where range.upperBound >= left && range.lowerBound <= right {
            let x0 = x(range.lowerBound), x1 = x(range.upperBound)
            let rect = CGRect(x: x0, y: size.height - 5, width: max(1, x1 - x0), height: 3)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(.white.opacity(0.32)))
        }

        // Ticks + labels, chosen so minor ticks stay ≥ 9 pt apart and labels ≥ 64 pt.
        let steps: [Double] = [60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600]
        let minor = steps.first { $0 / spp >= 9 } ?? 21600
        let label = steps.first { $0 / spp >= 64 } ?? 21600
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: Date(timeIntervalSince1970: left)).timeIntervalSince1970
        var t = dayStart + floor((left - dayStart) / minor) * minor
        while t <= right {
            let px = x(t)
            let isLabel = (t - dayStart).truncatingRemainder(dividingBy: label) == 0
            let tickH: CGFloat = isLabel ? 10 : 5
            let rect = CGRect(x: px - 0.5, y: Self.labelBand + 2, width: 1, height: tickH)
            ctx.fill(Path(rect), with: .color(.white.opacity(isLabel ? 0.45 : 0.18)))
            if isLabel {
                let text = Text(tickLabel(t, step: label))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.55))
                ctx.draw(text, at: CGPoint(x: px, y: 0), anchor: .top)
            }
            t += minor
        }

        // Day boundaries — a stronger line with the date, so crossing midnight is never ambiguous.
        var midnight = dayStart
        while midnight <= right {
            if midnight >= left {
                let px = x(midnight)
                ctx.fill(Path(CGRect(x: px - 0.5, y: Self.labelBand, width: 1, height: size.height - Self.labelBand - 2)),
                         with: .color(.white.opacity(0.22)))
                let text = Text(Date(timeIntervalSince1970: midnight)
                        .formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(GlassTheme.primary)
                ctx.draw(text, at: CGPoint(x: px + 4, y: Self.labelBand + 14), anchor: .topLeading)
            }
            midnight += 86400
        }

        // Event pills, colour by object, laid into lanes so overlapping tracks don't merge.
        let minWidth: CGFloat = 4
        for event in events {
            guard let start = event.startTime else { continue }
            let end = max(event.endTime ?? start + 10, start + Double(minWidth) * spp)
            guard end >= left, start <= right else { continue }
            let lane = lanes[event.id] ?? 0
            let x0 = x(start), x1 = x(end)
            let rect = CGRect(x: x0, y: Self.eventTop + CGFloat(lane) * Self.laneHeight,
                              width: max(minWidth, x1 - x0), height: Self.laneHeight - 2)
            let color = TimelineStyle.color(for: event.label)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color.opacity(0.92)))
        }

        // The future — hatched so it reads as "not recorded yet", not as an empty gap.
        if now < right {
            let x0 = max(0, x(now))
            var future = ctx
            future.clip(to: Path(CGRect(x: x0, y: 0, width: size.width - x0, height: size.height)))
            future.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.42)))
            var hatch = Path()
            var hx = x0 - size.height
            while hx < size.width {
                hatch.move(to: CGPoint(x: hx, y: size.height))
                hatch.addLine(to: CGPoint(x: hx + size.height, y: 0))
                hx += 9
            }
            future.stroke(hatch, with: .color(.white.opacity(0.07)), lineWidth: 1)
        }
    }

    private func tickLabel(_ t: Double, step: Double) -> String {
        let date = Date(timeIntervalSince1970: t)
        let minute = Calendar.current.component(.minute, from: date)
        if step >= 3600 || minute == 0 {
            return date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
        }
        return date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
    }

    /// The fixed playhead, with the exact time riding on it — so the number you read is always
    /// the moment under the line, whatever the ruler is doing.
    private func playhead(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text(Date(timeIntervalSince1970: engine.center)
                    .formatted(.dateTime.hour().minute().second()))
                .font(.system(size: 11, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.black)
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(GlassTheme.accent, in: Capsule())
            Triangle()
                .fill(GlassTheme.accent)
                .frame(width: 12, height: 6)
            Rectangle()
                .fill(GlassTheme.accent)
                .frame(width: 2)
        }
        .frame(height: height)
        .shadow(color: GlassTheme.accent.opacity(0.7), radius: engine.isInteracting ? 6 : 3)
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: engine.isInteracting)
    }

    // MARK: - Zoom chip

    private static let zoomPresets: [Double] = [10 * 60, 3600, 6 * 3600, 24 * 3600]

    private var zoomLabel: String {
        let v = engine.visibleSeconds
        return v < 3600 ? "\(Int((v / 60).rounded()))m" : "\(Int((v / 3600).rounded()))h"
    }

    /// One-thumb zoom for when a pinch is awkward: cycles 10m → 1h → 6h → 24h.
    private var zoomChip: some View {
        Button {
            Haptics.select()
            let next = Self.zoomPresets.first { $0 > engine.visibleSeconds + 1 } ?? Self.zoomPresets[0]
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { engine.zoom(to: next) }
        } label: {
            Text(zoomLabel)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(GlassTheme.secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background {
                    Capsule().fill(GlassTheme.surface)
                    Capsule().strokeBorder(GlassTheme.separator, lineWidth: 1)
                }
                .hitTarget()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Timeline zoom, \(zoomLabel) across the screen")
        .padding(.trailing, GlassTheme.Space.s)
        .padding(.bottom, 2)
    }

    // MARK: - Lanes

    /// Greedy lane packing over the whole list: an event takes the first lane whose previous
    /// occupant ended before it starts. Overflow wraps, which only happens in genuinely dense
    /// stretches where a merged bar is the honest picture anyway.
    private func assignLanes() {
        var lastEnd = Array(repeating: -Double.infinity, count: Self.laneCount)
        var result: [String: Int] = [:]
        let sorted = events.sorted { ($0.startTime ?? 0) < ($1.startTime ?? 0) }
        for (i, event) in sorted.enumerated() {
            guard let start = event.startTime else { continue }
            let end = max(event.endTime ?? start + 10, start + 10)
            if let free = lastEnd.indices.first(where: { lastEnd[$0] + 2 <= start }) {
                result[event.id] = free
                lastEnd[free] = end
            } else {
                let lane = i % Self.laneCount
                result[event.id] = lane
                lastEnd[lane] = end
            }
        }
        lanes = result
    }

    // MARK: - Gestures

    private func drag(spp: Double) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartCenter == nil {
                    beginInteraction()
                    dragStartCenter = engine.center
                }
                guard let origin = dragStartCenter else { return }
                move(to: origin - Double(value.translation.width) * spp, spp: spp)
            }
            .onEnded { value in
                dragStartCenter = nil
                guard pinchStartVisible == nil else { return }
                // A flick coasts. Below the threshold it's a placement, and coasting a placement
                // makes the playhead drift off the moment the user just chose.
                let velocity = Double(value.velocity.width)
                if abs(velocity) > 150, !reduceMotion {
                    coast(velocityPointsPerSecond: -velocity, spp: spp)
                } else {
                    endInteraction()
                }
            }
    }

    private func pinch() -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStartVisible == nil {
                    beginInteraction()
                    pinchStartVisible = engine.visibleSeconds
                    hitZoomLimit = false
                }
                guard let start = pinchStartVisible else { return }
                let limited = engine.zoom(to: start / Double(value.magnification))
                if limited, !hitZoomLimit { Haptics.impact(.rigid); hitZoomLimit = true }
                if !limited { hitZoomLimit = false }
            }
            .onEnded { _ in
                pinchStartVisible = nil
                if dragStartCenter == nil { endInteraction() }
            }
    }

    private func tapped(at location: CGPoint, left: Double, spp: Double) {
        let t = left + Double(location.x) * spp
        let tolerance = 10 * spp
        let nearest = events
            .compactMap { e -> (FrigateEvent, Double)? in
                guard let s = e.startTime else { return nil }
                let end = e.endTime ?? s + 10
                let d = t < s ? s - t : (t > end ? t - end : 0)
                return (e, d)
            }
            .min { $0.1 < $1.1 }
        if let (event, distance) = nearest, distance <= tolerance {
            Haptics.tap()
            onTapEvent(event)
        } else {
            Haptics.select()
            engine.center = engine.clamped(t)
            onScrubEnd(engine.center)
        }
    }

    // MARK: - Interaction lifecycle

    private func beginInteraction() {
        coastTask?.cancel()
        coastTask = nil
        engine.isInteracting = true
        lastHapticEventID = nil
        lastHapticHour = Int(floor(engine.center / 3600))
        hitEdge = false
        Haptics.select()
    }

    private func endInteraction() {
        engine.isInteracting = false
        onScrubEnd(engine.center)
    }

    /// Moves the playhead with a soft stop at the live edge and the oldest day: past either the
    /// ruler only follows a quarter of the finger, then snaps back on release.
    private func move(to proposed: Double, spp: Double) {
        let clamped = engine.clamped(proposed)
        let overshoot = proposed - clamped
        engine.center = clamped + overshoot * 0.25
        haptics(spp: spp, atEdge: overshoot != 0)
    }

    private func coast(velocityPointsPerSecond: Double, spp: Double) {
        coastTask?.cancel()
        coastTask = Task { @MainActor in
            var v = velocityPointsPerSecond * spp   // seconds per second
            let dt = 1.0 / 60
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_000_000)
                v *= 0.93
                let next = engine.center + v * dt
                let clamped = engine.clamped(next)
                if clamped != next { engine.center = clamped; break }   // hit an edge: stop dead
                engine.center = next
                haptics(spp: spp, atEdge: false)
                if abs(v * dt) < spp * 0.35 { break }                 // sub-pixel: settled
            }
            guard !Task.isCancelled else { return }
            engine.center = engine.clamped(engine.center)
            endInteraction()
        }
    }

    /// The tactile layer: a selection tick when the playhead crosses a detection, a light knock
    /// on each hour at working zooms, and one firm bump when it hits the live edge.
    private func haptics(spp: Double, atEdge: Bool) {
        let c = engine.center
        let near = events.first { e in
            guard let s = e.startTime else { return false }
            return abs(s - c) <= 4 * spp
        }
        if let near, near.id != lastHapticEventID { Haptics.select() }
        lastHapticEventID = near?.id

        if engine.visibleSeconds <= 4 * 3600 {
            let hour = Int(floor(c / 3600))
            if let last = lastHapticHour, hour != last { Haptics.impact(.light) }
            lastHapticHour = hour
        }

        if atEdge, !hitEdge { Haptics.impact(.rigid) }
        hitEdge = atEdge
    }
}

/// Object → category → colour, shared by the ruler pills, the Moments strip and the filter chips
/// so one legend explains all three. Person is the hot colour because it is the one that matters
/// at a glance; vehicles are the calm one.
enum TimelineStyle {
    enum Category: String, CaseIterable, Identifiable {
        case person, vehicle, animal, package, other
        var id: String { rawValue }
        var title: String {
            switch self {
            case .person: return "People"
            case .vehicle: return "Vehicles"
            case .animal: return "Animals"
            case .package: return "Packages"
            case .other: return "Other"
            }
        }
        var color: Color {
            switch self {
            case .person: return GlassTheme.red
            case .vehicle: return GlassTheme.green
            case .animal: return .yellow
            case .package: return GlassTheme.cyan
            case .other: return GlassTheme.purple
            }
        }
    }

    static func category(for label: String) -> Category {
        switch label.lowercased() {
        case "person": return .person
        case "car", "truck", "bus", "vehicle", "motorcycle_vehicle", "bicycle", "motorcycle": return .vehicle
        case "dog", "cat", "bird", "deer", "fox", "raccoon", "horse", "bear", "rabbit", "squirrel", "animal":
            return .animal
        case "package": return .package
        default: return .other
        }
    }

    static func color(for label: String) -> Color { category(for: label).color }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
