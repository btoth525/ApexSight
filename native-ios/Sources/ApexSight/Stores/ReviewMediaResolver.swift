import Foundation

/// What a review row / detail screen should actually show, resolved once and remembered.
///
/// A review is a *container*: `data.detections` is an unordered list of event ids that can span
/// several objects and several minutes, and the row's caption is built from the review's
/// deduplicated `objects` + `sub_labels` — not from any one detection. So "which detection is this
/// row about" is a real question, and getting it wrong is what makes History show the wrong
/// history: a row captioned "Dog — Chico" whose still and clip came from the person beside the dog.
///
/// This resolves three things together, because they all need the same event fetch:
///  1. the **primary detection** (title-aware — see `FrigateClient.titleMatchedDetectionID`),
///  2. whether that detection has a **playable clip** at all, and
///  3. a one-line **debug string** naming exactly what was chosen (see `ReviewMediaDebug`).
///
/// **Fail-quiet, like `ReviewStillResolver`.** Every failure path degrades to the synchronous
/// `thumb_time` answer and an unprobed clip URL — the behaviour before this type existed. A slow or
/// unreachable server must never be able to blank a row that would otherwise have rendered.
struct ReviewMediaPlan: Equatable {
    /// The detection the row is about. Nil only when the review lists none.
    var detectionID: String?
    /// The looping preview clip, or nil when there is nothing playable (no clip on the event, or
    /// the clamped window contains no recording). Nil means "show the still alone" — never means
    /// "keep whatever was playing before".
    var clipURL: URL?
    /// True once the clip URL has actually been probed. Distinguishes "verified playable" from
    /// "assumed playable because the probe didn't finish", which matters when reading the overlay.
    var clipVerified: Bool = false
    /// Why this plan looks the way it does — rendered by the debug overlay only.
    var debug: String = ""
}

@MainActor
final class ReviewMediaResolver {
    static let shared = ReviewMediaResolver()

    /// reviewID → plan. Only FINISHED reviews are cached: Frigate keeps re-choosing a live
    /// review's best frame and can still append detections to it, so caching an in-progress
    /// answer would pin the row to a moment that is still moving.
    private var cache: [String: ReviewMediaPlan] = [:]
    /// Coalesces concurrent asks for the same review — a row scrolling in and out of a `List`
    /// must not stack duplicate event fetches.
    private var inFlight: [String: Task<ReviewMediaPlan, Never>] = [:]

    /// Which detection a review is about, plus how that was decided. Cached separately from the
    /// full plan so an id-only caller never triggers the clip probe.
    struct DetectionChoice { var id: String?; var how: String; var event: FrigateEvent? }
    private var detectionCache: [String: DetectionChoice] = [:]
    private var detectionInFlight: [String: Task<DetectionChoice, Never>] = [:]

    private init() {}

    /// The synchronous answer, good enough to render immediately and correct for the large
    /// majority of reviews. The async `plan(for:)` refines it when it can.
    nonisolated static func quickPlan(for review: FrigateReviewItem, client: FrigateClient?) -> ReviewMediaPlan {
        let id = FrigateClient.primaryDetectionID(of: review)
        guard let client, let id else { return ReviewMediaPlan(detectionID: id) }
        return ReviewMediaPlan(
            detectionID: id,
            clipURL: client.eventPlaybackURL(id: id, camera: review.camera,
                                             start: review.startTime, end: review.endTime),
            clipVerified: false,
            debug: "quick(thumb_time)"
        )
    }

    func plan(for review: FrigateReviewItem, client: FrigateClient?) async -> ReviewMediaPlan {
        guard let client else { return ReviewMediaPlan() }
        let finished = review.endTime != nil
        if finished, let cached = cache[review.id] { return cached }
        if let running = inFlight[review.id] { return await running.value }

        // Reuse the cached/in-flight detection choice rather than re-deriving it: for the 4% of
        // reviews that need title-matching that would otherwise fetch every detection's event twice.
        let choice = await detectionChoice(for: review, client: client)
        let task = Task<ReviewMediaPlan, Never> { [weak self] in
            let plan = await Self.resolveClip(review: review, choice: choice, client: client)
            if finished { self?.cache[review.id] = plan }
            self?.inFlight[review.id] = nil
            // One line per RESOLVED review (not per render — this runs once and is then cached),
            // so a "wrong video" report can be read back off the relay instead of reproduced.
            DiagnosticLog.shared.log(.info, "review-media", Self.describe(review: review, plan: plan))
            return plan
        }
        inFlight[review.id] = task
        return await task.value
    }

    /// The title-aware primary detection, shared with `ReviewStillResolver` so the still and the
    /// clip can never disagree about which moment the row is showing.
    ///
    /// Deliberately does NOT run the clip probe. `ReviewStillResolver` is also reached from the
    /// CarPlay list and the local alert notifier, and those only ever want a picture — making them
    /// fetch an HLS playlist to answer "which detection" would put a pointless request on a
    /// notification path. `plan(for:)` layers the clip work on top of this.
    func primaryDetectionID(for review: FrigateReviewItem, client: FrigateClient?) async -> String? {
        guard let client else { return FrigateClient.primaryDetectionID(of: review) }
        return await detectionChoice(for: review, client: client).id
            ?? FrigateClient.primaryDetectionID(of: review)
    }

    /// Cached + coalesced "which detection", shared by the still resolver and the clip plan.
    private func detectionChoice(for review: FrigateReviewItem,
                                 client: FrigateClient) async -> DetectionChoice {
        let finished = review.endTime != nil
        if finished, let cached = detectionCache[review.id] { return cached }
        if let running = detectionInFlight[review.id] { return await running.value }

        let task = Task<DetectionChoice, Never> { [weak self] in
            let choice = await Self.resolveDetection(review: review, client: client)
            if finished { self?.detectionCache[review.id] = choice }
            self?.detectionInFlight[review.id] = nil
            return choice
        }
        detectionInFlight[review.id] = task
        return await task.value
    }

    /// Drops every cached answer — for a server/account switch, where the same review id could
    /// belong to a different Frigate.
    func reset() {
        cache.removeAll()
        detectionCache.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        detectionInFlight.values.forEach { $0.cancel() }
        detectionInFlight.removeAll()
    }

    // MARK: - Resolution

    /// WHICH detection the row is about. No clip work — see `primaryDetectionID(for:client:)`.
    private nonisolated static func resolveDetection(review: FrigateReviewItem,
                                                     client: FrigateClient) async -> DetectionChoice {
        let ids = review.data?.detections ?? []
        guard var chosen = FrigateClient.primaryDetectionID(of: review) else {
            return DetectionChoice(id: nil, how: "no detections on review", event: nil)
        }

        var how = "thumb_time"
        var chosenEvent: FrigateEvent?

        // Only pay for the extra fetches when title-matching could actually change the answer:
        // the review must name somebody AND have more than one detection to disagree about.
        // Measured live 2026-09-12 this is 7 of 174 reviews (4%), so the common row costs nothing.
        if Self.needsTitleMatch(review) {
            var events: [FrigateEvent] = []
            await withTaskGroup(of: FrigateEvent?.self) { group in
                for id in ids { group.addTask { try? await client.event(id: id) } }
                for await event in group { if let event { events.append(event) } }
            }
            if let matched = FrigateClient.titleMatchedDetectionID(of: review, among: events) {
                if matched != chosen { how = "title-match(sub_label)" }
                chosen = matched
            } else if !events.isEmpty {
                how = "thumb_time (no detection carries the title name)"
            }
            chosenEvent = events.first { $0.id == chosen }
        }
        return DetectionChoice(id: chosen, how: how, event: chosenEvent)
    }

    /// The clip half: given an already-resolved detection, decide what (if anything) can play.
    private nonisolated static func resolveClip(review: FrigateReviewItem,
                                                choice: DetectionChoice,
                                                client: FrigateClient) async -> ReviewMediaPlan {
        guard let chosen = choice.id else {
            return ReviewMediaPlan(detectionID: nil, clipURL: nil, clipVerified: false,
                                   debug: choice.how)
        }
        let how = choice.how
        var chosenEvent = choice.event
        if chosenEvent == nil { chosenEvent = try? await client.event(id: chosen) }

        // No clip on the event at all → still only. Frigate's plate-reader helper camera
        // (Front_Driveway_LPR) stores snapshot-only events and never has recordings; its
        // `/vod/event/<id>/master.m3u8` 404s (verified 2026-09-12).
        if chosenEvent?.hasClip == false {
            return ReviewMediaPlan(detectionID: chosen, clipURL: nil, clipVerified: true,
                                   debug: "\(how) · has_clip=false → still only")
        }

        let candidate = client.eventPlaybackURL(id: chosen, camera: review.camera,
                                                start: review.startTime, end: review.endTime)
        // Probe the window. An empty range returns a 200 master playlist with no segments, so a
        // status check alone would hand AVPlayer a playlist it can only stall on.
        let playable = await client.hlsWindowHasVideo(candidate)
        return ReviewMediaPlan(
            detectionID: chosen,
            clipURL: playable ? candidate : nil,
            clipVerified: true,
            debug: "\(how) · \(playable ? "clip ok" : "no recording in window → still only")"
        )
    }

    /// The audit line: review id, chosen detection, what the row is captioned with, and the exact
    /// video URL — everything needed to see a mismatch without reproducing it on the phone.
    nonisolated static func describe(review: FrigateReviewItem, plan: ReviewMediaPlan) -> String {
        let objects = (review.data?.objects ?? []).joined(separator: "+")
        let subs = (review.data?.subLabels ?? []).filter { !$0.isEmpty }.joined(separator: "+")
        let det = plan.detectionID ?? "none"
        let video = plan.clipURL?.absoluteString ?? "none (still only)"
        return "review=\(review.id) cam=\(review.camera) objects=[\(objects)] "
            + "sub_labels=[\(subs)] → detection=\(det) · \(plan.debug) · video=\(video)"
    }

    /// True when the row names somebody and its detections could disagree about who that is.
    nonisolated static func needsTitleMatch(_ review: FrigateReviewItem) -> Bool {
        let subs = (review.data?.subLabels ?? []).filter { !$0.isEmpty }
        guard !subs.isEmpty else { return false }
        return (review.data?.detections?.count ?? 0) > 1
    }
}
