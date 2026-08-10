import Foundation

/// Decides whether a review's still image can be trusted, or has to be pinned to a moment.
///
/// A review's picture is resolved through one of its detections, and `/api/events/<id>/snapshot.jpg`
/// serves that tracked object's *current best frame*. Frigate keeps re-choosing that frame for as
/// long as the track lives and re-links long-lived parked tracks into fresh reviews — so the frame
/// can sit a long way outside the review that referenced it.
///
/// Measured against the live server over 3 days (157 alert reviews with a resolvable detection):
/// **27 showed a frame from outside their own window**, 14 of them by more than a minute and 10 by
/// more than five. The worst was a review at 08-08 08:35 whose image was a *different vehicle* from
/// 08-07 16:02 — 16.5 hours earlier, with Frigate's burnt-in timestamp on the frame proving it.
/// That image is what the Review list row shows, so it is the first thing the user sees.
///
/// `thumb_time` is NOT a safe substitute: on the 130 reviews whose frame IS in-window, the best
/// frame differs from `thumb_time` by a median 1.8s but exceeds 3s on 44% of them and reaches 91s.
/// Swapping everything to `thumb_time` would degrade the majority to fix the minority. So this
/// mirrors what the push relay already does server-side (`bridge._best_frame_time`): keep the
/// object's own frame when it genuinely falls inside the review, and pin a recording frame only
/// when it does not.
///
/// **Fail-quiet**: every uncertain input returns nil, meaning "leave the existing image alone".
/// A missing snapshot time, an unreadable event, or a nonsense timestamp must never be able to
/// take away a picture the user would otherwise have seen.
enum ReviewStillPolicy {

    /// Slack, in seconds, before a frame just outside the window counts as outside it. Frigate's
    /// review bounds and the frame clock are not sampled from the same tick, so a frame a fraction
    /// of a second past the edge is the right image and must not trigger a pointless swap.
    static let tolerance: Double = 1.0

    /// The moment to pin this review's still to, or nil to keep the object's own snapshot.
    ///
    /// - Parameters:
    ///   - snapshotFrameTime: the event's `data.snapshot_frame_time`.
    ///   - reviewStart: the review's `start_time`.
    ///   - reviewEnd: the review's effective end — pass `now` for a review still in progress, so a
    ///     frame chosen moments ago reads as in-window rather than being needlessly pinned.
    /// - Returns: a timestamp clamped into the review's window, or nil when the existing frame is
    ///   already inside it (or the inputs can't be trusted).
    static func pinnedFrameTime(snapshotFrameTime: Double?,
                                reviewStart: Double?,
                                reviewEnd: Double?) -> Double? {
        guard let frame = snapshotFrameTime, frame.isFinite, frame > 0,
              let start = reviewStart, start.isFinite, start > 0 else { return nil }

        // A malformed or absent end can't shrink the window below its start.
        let end = max(start, (reviewEnd?.isFinite == true ? reviewEnd! : start))

        if frame >= start - tolerance && frame <= end + tolerance { return nil }
        return min(max(frame, start), end)
    }
}
