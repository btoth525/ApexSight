import Testing
@testable import ApexSightNative

/// Guards the decision behind a review's picture.
///
/// The bug this exists to prevent shipped and was measured on the live server: a review at
/// 08-08 08:35 rendered a frame from 08-07 16:02 — a *different vehicle*, 16.5 hours earlier —
/// because `/api/events/<id>/snapshot.jpg` serves a tracked object's current best frame and
/// Frigate keeps re-choosing it for as long as a parked car stays in view. 27 of 157 reviews were
/// affected, 10 of them by more than five minutes.
///
/// The opposite failure is just as real: pinning a review whose frame is fine would swap a
/// purpose-chosen best frame for an arbitrary recording moment on 83% of reviews. So these tests
/// pin BOTH directions — pins when it must, and stays out of the way when it must not.
@Suite("ReviewStillPolicy")
struct ReviewStillPolicyTests {
    private let start: Double = 1_786_196_117
    private let end: Double = 1_786_196_131

    // MARK: - Leaves a correct image alone

    @Test("No pin when the frame is inside the review")
    func inWindow() {
        #expect(ReviewStillPolicy.pinnedFrameTime(snapshotFrameTime: start + 5,
                                                  reviewStart: start, reviewEnd: end) == nil)
    }

    @Test("No pin on the exact boundaries")
    func onBoundaries() {
        #expect(ReviewStillPolicy.pinnedFrameTime(snapshotFrameTime: start,
                                                  reviewStart: start, reviewEnd: end) == nil)
        #expect(ReviewStillPolicy.pinnedFrameTime(snapshotFrameTime: end,
                                                  reviewStart: start, reviewEnd: end) == nil)
    }

    /// Review bounds and the frame clock aren't sampled from the same tick — a frame a fraction of
    /// a second past the edge is the right image, and swapping it would be a pointless flicker.
    @Test("No pin for a sub-second overshoot within tolerance")
    func withinTolerance() {
        #expect(ReviewStillPolicy.pinnedFrameTime(snapshotFrameTime: end + 0.4,
                                                  reviewStart: start, reviewEnd: end) == nil)
        #expect(ReviewStillPolicy.pinnedFrameTime(snapshotFrameTime: start - 0.9,
                                                  reviewStart: start, reviewEnd: end) == nil)
    }

    // MARK: - Pins a wrong image

    /// The real measured case, to the second.
    @Test("Pins the 16.5-hour-stale parked-car frame back into the review")
    func pinsTheRealRegression() {
        let staleFrame: Double = 1_786_136_539   // 08-07 16:02, from a track that outlived its review
        let pinned = ReviewStillPolicy.pinnedFrameTime(snapshotFrameTime: staleFrame,
                                                       reviewStart: start, reviewEnd: end)
        #expect(pinned == start)
    }

    @Test("Pins a frame chosen after the review ended")
    func pinsFutureFrame() {
        #expect(ReviewStillPolicy.pinnedFrameTime(snapshotFrameTime: end + 3_600,
                                                  reviewStart: start, reviewEnd: end) == end)
    }

    @Test("The pinned time is always inside the review window")
    func pinnedTimeIsClamped() {
        for frame in [start - 90_000, start - 61, end + 61, end + 90_000] {
            let pinned = ReviewStillPolicy.pinnedFrameTime(snapshotFrameTime: frame,
                                                           reviewStart: start, reviewEnd: end)
            let value = try! #require(pinned)
            #expect(value >= start && value <= end)
        }
    }

    // MARK: - Fail-quiet: never take away an image

    @Test("Untrustworthy input never pins")
    func failsQuiet() {
        #expect(ReviewStillPolicy.pinnedFrameTime(snapshotFrameTime: nil,
                                                  reviewStart: start, reviewEnd: end) == nil)
        #expect(ReviewStillPolicy.pinnedFrameTime(snapshotFrameTime: start + 5,
                                                  reviewStart: nil, reviewEnd: end) == nil)
        #expect(ReviewStillPolicy.pinnedFrameTime(snapshotFrameTime: 0,
                                                  reviewStart: start, reviewEnd: end) == nil)
        #expect(ReviewStillPolicy.pinnedFrameTime(snapshotFrameTime: -1,
                                                  reviewStart: start, reviewEnd: end) == nil)
        #expect(ReviewStillPolicy.pinnedFrameTime(snapshotFrameTime: .nan,
                                                  reviewStart: start, reviewEnd: end) == nil)
        #expect(ReviewStillPolicy.pinnedFrameTime(snapshotFrameTime: .infinity,
                                                  reviewStart: start, reviewEnd: end) == nil)
    }

    /// A review with no end (still in progress) is handed `now` by the resolver, but a malformed
    /// end must not produce a window that ends before it starts.
    @Test("A missing or malformed end degrades to a zero-length window, never an inverted one")
    func malformedEnd() {
        #expect(ReviewStillPolicy.pinnedFrameTime(snapshotFrameTime: start,
                                                  reviewStart: start, reviewEnd: nil) == nil)
        #expect(ReviewStillPolicy.pinnedFrameTime(snapshotFrameTime: start + 500,
                                                  reviewStart: start, reviewEnd: start - 900) == start)
        #expect(ReviewStillPolicy.pinnedFrameTime(snapshotFrameTime: start + 500,
                                                  reviewStart: start, reviewEnd: .nan) == start)
    }
}
