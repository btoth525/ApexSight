import SwiftUI

struct ReviewRow: View {
    @EnvironmentObject private var appState: AppState
    let review: FrigateReviewItem
    var onOpen: () -> Void = {}
    var onDismiss: () -> Void = {}

    private var isAlert: Bool { review.severity == "alert" }
    private var tint: Color { isAlert ? GlassTheme.orange : GlassTheme.cyan }

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
        .overlay(alignment: .topLeading) { severityBadge.padding(10) }
        // Frigate's GenAI story badge, opposite the severity badge. Deliberately shown ONLY when
        // the model rated the activity above routine — badging every delivery and passing car
        // would just train you to ignore it (see ThreatLevel.deservesRowBadge).
        .overlay(alignment: .topTrailing) { storyBadge.padding(10) }
        .cardStroke()
        .shadow(color: .black.opacity(0.22), radius: 9, y: 4)
    }

    /// Badge for Frigate's review-level GenAI rating, shown only above routine so the list stays
    /// scannable. Icon + word, never colour alone.
    @ViewBuilder
    private var storyBadge: some View {
        if let meta = review.data?.metadata, meta.hasContent {
            let level = ThreatLevel(raw: meta.potentialThreatLevel)
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

    @ViewBuilder
    private var hero: some View {
        if let url = appState.client?.reviewSnapshotURL(review: review)
            ?? appState.client?.reviewThumbnailURL(review: review) {
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
                            fallbackURL: appState.client?.reviewThumbnailURL(review: review))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
