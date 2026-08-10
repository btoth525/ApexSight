import Foundation

/// Resolves the still image a review should actually show, and remembers the answer.
///
/// The decision itself is `ReviewStillPolicy`; this is the plumbing around it — one small event
/// fetch per review, cached, so scrolling the Review list doesn't re-ask. Answering needs the
/// event's `snapshot_frame_time`, which is only in the event JSON, so it cannot be a synchronous
/// URL builder like the rest of `FrigateClient`.
///
/// **A finished review's answer is fixed; an in-progress one's is not.** Frigate keeps upgrading a
/// live object's snapshot to a better frame, so caching the resolve for a review still in progress
/// would reintroduce exactly the stale-image bug the `revalidate` flag exists to prevent. Only
/// finished reviews are cached.
///
/// **This can only ever add an image, never remove one.** Every failure path — no detection, event
/// unreadable, no snapshot time, frame already in-window — returns nil, which leaves the caller on
/// the snapshot URL it would have used anyway.
@MainActor
final class ReviewStillResolver {
    static let shared = ReviewStillResolver()

    /// reviewID → the pinned URL, or nil for "the existing snapshot is correct". Only holds
    /// entries for FINISHED reviews (see the type doc).
    private var cache: [String: URL?] = [:]
    /// Coalesces concurrent asks for the same review — a row scrolling in and out shouldn't
    /// stack duplicate event fetches.
    private var inFlight: [String: Task<URL?, Never>] = [:]

    private init() {}

    /// The URL to show instead of the review's own snapshot, or nil to keep the existing one.
    func pinnedStill(for review: FrigateReviewItem, client: FrigateClient?) async -> URL? {
        guard let client else { return nil }
        let isFinished = review.endTime != nil
        if isFinished, let cached = cache[review.id] { return cached }
        if let running = inFlight[review.id] { return await running.value }

        let task = Task<URL?, Never> { [weak self] in
            let url = await Self.resolve(review: review, client: client)
            if isFinished { self?.cache[review.id] = url }
            self?.inFlight[review.id] = nil
            return url
        }
        inFlight[review.id] = task
        return await task.value
    }

    /// Drops every cached answer — for a server/account switch, where the same review id could
    /// belong to a different Frigate.
    func reset() {
        cache.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    private nonisolated static func resolve(review: FrigateReviewItem,
                                            client: FrigateClient) async -> URL? {
        guard let detectionID = FrigateClient.primaryDetectionID(of: review) else { return nil }
        guard let event = try? await client.event(id: detectionID) else { return nil }

        // An in-progress review's window runs up to NOW; a frame chosen moments ago belongs to it.
        let effectiveEnd = review.endTime ?? Date().timeIntervalSince1970
        guard let pinned = ReviewStillPolicy.pinnedFrameTime(snapshotFrameTime: event.snapshotFrameTime,
                                                             reviewStart: review.startTime,
                                                             reviewEnd: effectiveEnd) else { return nil }
        return client.recordingFrameURL(camera: review.camera, at: pinned)
    }
}
