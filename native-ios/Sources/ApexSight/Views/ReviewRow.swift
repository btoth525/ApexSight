import SwiftUI

struct ReviewRow: View {
    @EnvironmentObject private var appState: AppState
    let review: FrigateReviewItem
    var onOpen: () -> Void = {}
    var onDismiss: () -> Void = {}

    private var isAlert: Bool { review.severity == "alert" }
    private var tint: Color { isAlert ? GlassTheme.orange : GlassTheme.cyan }

    /// Set only when this review's own snapshot belongs to a different moment — see
    /// `ReviewStillPolicy`. Nil (the common case) leaves the image exactly as it was.
    @State private var pinnedStill: URL?
    /// Hold the looping preview hidden until it can actually paint, so a not-yet-ready clip never
    /// composites a blank/partial frame over the poster.
    @State private var videoReady = false
    /// Which detection this row is about, and the clip for it. Starts as the synchronous
    /// `thumb_time` answer so the row is never empty, then refines — see `ReviewMediaResolver`.
    @State private var plan = ReviewMediaPlan()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) { card }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint("Opens this review")
            // Fast "got it" dismiss — clears the item without opening it.
            dismissButton
                .padding(10)
        }
        // Re-asks while the review is in progress (its best frame is still moving), then once
        // more when it finishes — the same rule `snapshotStillChanging` applies to the image.
        .task(id: "\(review.id)|\(snapshotStillChanging)") {
            pinnedStill = await ReviewStillResolver.shared.pinnedStill(for: review,
                                                                       client: appState.client)
        }
        // Resolve WHICH detection this row is about, and whether it has a playable clip.
        // Keyed on `review.id` so a recycled row can never keep showing the previous review's
        // clip: the plan is reset to this review's own synchronous answer before anything awaits.
        .task(id: review.id) {
            videoReady = false
            plan = ReviewMediaResolver.quickPlan(for: review, client: appState.client)
            let resolved = await ReviewMediaResolver.shared.plan(for: review, client: appState.client)
            guard !Task.isCancelled else { return }
            if resolved.clipURL != plan.clipURL { videoReady = false }
            plan = resolved
        }
    }

    /// A spoken summary of the card so VoiceOver doesn't read the layered image + gradient as
    /// separate fragments: "Alert. Person — Alex. Front Door • Zone: Porch."
    private var accessibilityLabel: String {
        let kind = isAlert ? "Alert" : "Detection"
        return "\(kind). \(NotificationCopy.combinedTitle(for: review)). \(subtitle)"
    }

    // MARK: - Big glanceable card

    private var card: some View {
        ZStack(alignment: .bottomLeading) {
            hero
            LinearGradient(
                colors: [.clear, .clear, .black.opacity(0.85)],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
            info
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous))
        // Severity and the AI rating sit TOGETHER at the top-left: "what kind of event" then "how
        // serious", which reads as one thought. The top-RIGHT is the dismiss button's — putting
        // the rating there stacked the two on top of each other.
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                severityBadge
                storyBadge
            }
            .padding(10)
            // Never grow under the dismiss button (44pt + its 10pt padding) at large Dynamic Type.
            .padding(.trailing, 54)
        }
        .cardStroke()
        .shadow(color: .black.opacity(0.22), radius: 9, y: 4)
        .overlay(alignment: .bottom) {
            if Self.showMediaDebug { mediaDebugBadge }
        }
    }

    /// Opt-in on-device audit overlay for "this row is showing the wrong thing": the review id, the
    /// detection actually chosen, and the exact video URL.
    ///
    /// **DEBUG-only AND default-off**, so it cannot appear in a TestFlight build even if the key is
    /// somehow present. The durable version of this diagnostic is the one-line-per-review
    /// `review-media` entry in `DiagnosticLog`, which survives to the relay and is controlled by
    /// the existing Settings switch — read that first; this overlay is for eyeballing while scrolling.
    /// Enable in the simulator with:
    /// `xcrun simctl spawn booted defaults write group.com.brandontoth.apexsight apex.reviewMediaOverlay -bool YES`
    private static var showMediaDebug: Bool {
        #if DEBUG
        return UserDefaults(suiteName: ApexAppGroup.identifier)?
            .bool(forKey: "apex.reviewMediaOverlay") ?? false
        #else
        return false
        #endif
    }

    private var mediaDebugBadge: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("rev \(review.id)")
            Text("det \(plan.detectionID ?? "none") · \(plan.debug)")
            Text((plan.clipURL?.path ?? "video: none (still only)")
                 + (plan.clipVerified ? " ✓probed" : " ~unprobed"))
        }
        .font(.system(size: 8, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.72))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Badge for Frigate's review-level GenAI rating, shown only above routine so the list stays
    /// scannable. Icon + word, never colour alone.
    @ViewBuilder
    private var storyBadge: some View {
        // `trustedThreatLevel` is nil when the rating isn't believable (near-zero model
        // confidence, or a recognised resident) — that reads as unrated, so no badge at all.
        if let meta = review.data?.metadata, meta.hasContent,
           let level = review.trustedThreatLevel {
            if level.deservesRowBadge {
                HStack(spacing: 4) {
                    Image(systemName: level.symbol)
                        .font(.caption2.weight(.bold))
                    Text(level.label)
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, GlassTheme.Space.s)
                .padding(.vertical, 4)
                .background(level.tint.opacity(0.9), in: Capsule())
                .accessibilityElement(children: .combine)
                .accessibilityLabel("AI rating: \(level.label)")
            }
        }
    }

    /// Frigate keeps upgrading the detection's snapshot to the best frame while the review is
    /// live, then finalizes it at the end — so revalidate ONLY while in progress. A completed
    /// review's snapshot is fixed; re-fetching it every time the card scrolls back into view just
    /// re-downloaded the same image and flashed the card. (Matches ReviewDetailView.)
    private var snapshotStillChanging: Bool { review.endTime == nil }

    /// The object's own snapshot — correct for most reviews, and the fallback whenever the pinned
    /// recording frame can't be served (an aged-out segment must degrade to today's image, never
    /// to an empty card).
    private var objectStillURL: URL? {
        // Pinned to the SAME detection the clip plays, so the picture and the video can never
        // describe two different objects in one row.
        appState.client?.reviewSnapshotURL(review: review, detectionID: plan.detectionID)
            ?? appState.client?.reviewThumbnailURL(review: review, detectionID: plan.detectionID)
    }

    @ViewBuilder
    private var hero: some View {
        if let url = pinnedStill ?? objectStillURL {
            // The FULL frame, uncropped, on a flat dark background — so ultra-wide cameras show
            // the whole scene (subject never cropped out of frame), with no blown-up zoom.
            // 200pt card → downsample to ~700px so a 4K snapshot doesn't decode full-res
            // while the list scrolls.
            ZStack {
                Color.black
                // Fallback: cameras with snapshots disabled 404 the full snapshot — fall back to
                // the review's canonical thumbnail (always exists) instead of a gray placeholder.
                RemoteImage(url: url, contentMode: .fit, maxPixelSize: 700,
                            revalidate: snapshotStillChanging,
                            fallbackURL: pinnedStill == nil
                                ? appState.client?.reviewThumbnailURL(review: review,
                                                                      detectionID: plan.detectionID)
                                : objectStillURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Living thumbnail: the real footage loops (muted, HD) over the still.
                // `plan.clipURL` is nil when the event has no clip or the window holds no
                // recording — the still then stands alone, which is the ONLY fallback. It never
                // degrades to a previously loaded clip, because the plan is reset per review id.
                if let clip = plan.clipURL, let client = appState.client {
                    LoopingVideoView(url: clip, client: client,
                                     onFirstFrame: { withAnimation(.easeIn(duration: 0.25)) { videoReady = true } })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(videoReady ? 1 : 0)
                        .allowsHitTesting(false)
                        .onChange(of: clip) { _, _ in videoReady = false }
                }
            }
        } else {
            ZStack {
                Color.white.opacity(0.06)
                Image(systemName: isAlert ? "bell.badge.fill" : "scope")
                    .font(.system(size: 36, weight: .black))
                    .foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(NotificationCopy.combinedTitle(for: review))
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(subtitle)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
            if let epoch = review.startTime {
                Text(Date(timeIntervalSince1970: epoch).formatted(date: .abbreviated, time: .shortened))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .padding(14)
        // Semantic fonts scale with Dynamic Type (the list previously used fixed sizes and ignored
        // it); cap the growth so the text overlay can't outgrow the fixed thumbnail card.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private var severityBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: isAlert ? "bell.badge.fill" : "scope")
                .font(.system(size: 10, weight: .black))
            Text(isAlert ? "ALERT" : "DETECTION")
                .font(.system(size: 10, weight: .black))
            if let count = review.data?.detections?.count, count > 1 {
                Text("· \(count)").font(.system(size: 10, weight: .black))
            }
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tint, in: Capsule())
        .accessibilityHidden(true)
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "checkmark")
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.5), in: Circle())
                .overlay { Circle().stroke(.white.opacity(0.35), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Mark reviewed")
    }

    /// Camera + zone (the sub-label already lives in the title).
    private var subtitle: String {
        var parts = [titleize(review.camera)]
        if let zones = review.data?.zones, !zones.isEmpty {
            parts.append("Zone: " + zones.map(titleize).joined(separator: ", "))
        }
        return parts.joined(separator: " • ")
    }
}
