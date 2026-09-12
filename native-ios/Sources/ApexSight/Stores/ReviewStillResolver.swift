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

    /// reviewID → the pinned frame TIME, or nil for "the existing snapshot is correct". Only
    /// holds entries for FINISHED reviews (see the type doc).
    ///
    /// Deliberately not the URL: `recordingFrameURL` bakes in the client's `baseURL`, so caching
    /// the address meant a still resolved at home kept pointing at the LAN host after
    /// `onLocalNetwork` flipped and `AppState.client` switched to the tunnel. Every such row then
    /// burned RemoteImage's three attempts against an unreachable address and fell back to
    /// `objectStillURL` — exactly the wrong-moment snapshot ReviewStillPolicy exists to replace.
    /// The frame time is host-independent, so it survives the local↔remote flip and a server
    /// switch alike.
    private var cache: [String: Double?] = [:]
    /// Coalesces concurrent asks for the same review — a row scrolling in and out shouldn't
    /// stack duplicate event fetches.
    private var inFlight: [String: Task<Double?, Never>] = [:]

    private init() {}

    /// Remembers which pinned frame URLs Frigate actually serves, so the reachability probe below
    /// costs one request per distinct moment rather than one per row appearance.
    private var served: [String: Bool] = [:]

    /// The URL to show instead of the review's own snapshot, or nil to keep the existing one.
    /// Built against the CURRENT client, so it always names the host the app is talking to now.
    func pinnedStill(for review: FrigateReviewItem, client: FrigateClient?) async -> URL? {
        guard let client else { return nil }
        guard let pinned = await pinnedFrameTime(for: review, client: client) else { return nil }
        let url = client.recordingFrameURL(camera: review.camera, at: pinned)

        // **A pinned frame is only an improvement if the recording is actually there.** Pinning is
        // a swap away from the object's own (present, but possibly wrong-moment) snapshot, so
        // pointing it at a moment Frigate can't serve trades a slightly-wrong picture for a broken
        // one. Cameras that never record (Frigate's `Front_Driveway_LPR` plate-reader helper) and
        // moments whose segments have aged out both land here.
        //
        // GET, never HEAD — Frigate answers **405 to HEAD** on snapshot URLs (verified 2026-09-12),
        // so a HEAD probe would reject every frame and silently disable pinning altogether.
        let key = url.absoluteString
        if let known = served[key] { return known ? url : nil }
        let ok = await client.urlIsServed(url)
        served[key] = ok
        return ok ? url : nil
    }

    private func pinnedFrameTime(for review: FrigateReviewItem, client: FrigateClient) async -> Double? {
        let isFinished = review.endTime != nil
        if isFinished, let cached = cache[review.id] { return cached }
        if let running = inFlight[review.id] { return await running.value }

        // The SAME detection the row's clip uses, so the still and the video can never describe
        // two different moments (that divergence is half of "shows the wrong history").
        let detectionID = await ReviewMediaResolver.shared.primaryDetectionID(for: review,
                                                                             client: client)
        let task = Task<Double?, Never> { [weak self] in
            let pinned = await Self.resolve(review: review, detectionID: detectionID, client: client)
            if isFinished { self?.cache[review.id] = pinned }
            self?.inFlight[review.id] = nil
            return pinned
        }
        inFlight[review.id] = task
        return await task.value
    }

    /// Drops every cached answer — for a server/account switch, where the same review id could
    /// belong to a different Frigate.
    func reset() {
        cache.removeAll()
        served.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
    }

    private nonisolated static func resolve(review: FrigateReviewItem,
                                            detectionID: String?,
                                            client: FrigateClient) async -> Double? {
        guard let detectionID else { return nil }
        guard let event = try? await client.event(id: detectionID) else { return nil }

        // An in-progress review's window runs up to NOW; a frame chosen moments ago belongs to it.
        let effectiveEnd = review.endTime ?? Date().timeIntervalSince1970
        return ReviewStillPolicy.pinnedFrameTime(snapshotFrameTime: event.snapshotFrameTime,
                                                 reviewStart: review.startTime,
                                                 reviewEnd: effectiveEnd)
    }
}
