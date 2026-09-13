import Foundation
import Observation

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
///
/// `@Observable`, not `ObservableObject`, and the difference is the whole screen's frame budget:
/// `center` is written on every drag tick, every coast frame and 5×/s during playback. With
/// `objectWillChange` every one of those writes re-ran `RecordingTimelineView.body` — which
/// re-flattened and re-sorted every event and motion sample of the loaded days and re-diffed a
/// thousand moment cards, at gesture rate. Observation tracks per PROPERTY per VIEW, so a `center`
/// write now invalidates exactly the readout, the ruler and the strip that read it.
@Observable
@MainActor
final class TimelineEngine {
    /// Epoch under the playhead.
    var center: Double
    /// Seconds the ruler shows edge to edge. Width-independent, so rotating the phone or moving
    /// to an iPad doesn't change what "one hour across" means.
    var visibleSeconds: Double = 3600
    /// True while a finger is on the ruler (drag or pinch) or it is still coasting after a flick.
    /// Playback does not auto-follow while this is true, and the video surface shows the scrub
    /// preview instead of the paused frame.
    var isInteracting = false
    /// Oldest moment worth scrolling to — the start of the oldest day that has recordings. Nil
    /// until the day summary lands; the ruler then only rubber-bands against `latest`.
    var earliest: Double?
    /// Where the player's clock actually is — written by the follow loop while playing. Nil until
    /// the first playback lands. Lives here (not on the view) for the same reason as `center`:
    /// only the LIVE pill reads it, so only the LIVE pill should re-render for it.
    var playingTime: Double?

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

    /// Playback is at (within 45 s of) the live edge and nothing is holding it back.
    func isLive(playing: Bool) -> Bool {
        guard let playingTime, playing, !isInteracting else { return false }
        return latest - playingTime < 45
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
