import Foundation

/// The timeline's position and zoom — the one piece of state the ruler, the video surface and
/// the transport all read and write, so a drag on the ruler, a tap on "next event", and playback
/// itself all move the same playhead.
///
/// **The playhead is FIXED at the centre of the screen and the timeline moves under it.** That is
/// the Protect / Nest model, and it is what makes precision independent of screen width: at the
/// tightest zoom ten minutes span the screen (~1.7 s per point on an iPhone); at the widest, a whole
/// day does. The previous browser was the opposite — a thumb dragged across a fixed 24-hour bar —
/// which on a 360-point screen made every point worth four minutes, so no amount of care could
/// land on a moment.
@MainActor
final class TimelineEngine: ObservableObject {
    /// Epoch under the playhead.
    @Published var center: Double
    /// Seconds the ruler shows edge to edge. Width-independent, so rotating the phone or moving
    /// to an iPad doesn't change what "one hour across" means.
    @Published var visibleSeconds: Double = 3600
    /// True while a finger is on the ruler (drag or pinch) or it is still coasting after a flick.
    /// Playback does not auto-follow while this is true, and the video surface shows the scrub
    /// preview instead of the paused frame.
    @Published var isInteracting = false
    /// Oldest moment worth scrolling to — the start of the oldest day that has recordings. Nil
    /// until the day summary lands; the ruler then only rubber-bands against `latest`.
    @Published var earliest: Double?

    static let minVisibleSeconds: Double = 10 * 60
    static let maxVisibleSeconds: Double = 24 * 3600

    init(center: Double) { self.center = center }

    /// Newest allowed moment. Wall-clock; `RecordingTimelineView.playFrom` applies the extra flush margin
    /// when it actually asks Frigate for footage.
    var latest: Double { Date().timeIntervalSince1970 }

    func clamped(_ value: Double) -> Double {
        var v = min(value, latest)
        if let earliest { v = max(v, earliest) }
        return v
    }

    /// Applies a pinch: `factor` > 1 zooms in (fewer seconds across the screen).
    /// Returns true when the request ran into a zoom limit, so the caller can play a detent.
    @discardableResult
    func zoom(to visible: Double) -> Bool {
        let clamped = min(Self.maxVisibleSeconds, max(Self.minVisibleSeconds, visible))
        visibleSeconds = clamped
        return clamped != visible
    }
}
