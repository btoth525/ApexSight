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
            // Fast "got it" dismiss — clears the item without opening it.
            dismissButton
                .padding(10)
        }
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
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(alignment: .topLeading) { severityBadge.padding(10) }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
    }

    @ViewBuilder
    private var hero: some View {
        if let url = appState.client?.reviewSnapshotURL(review: review)
            ?? appState.client?.reviewThumbnailURL(review: review) {
            // The FULL frame, uncropped, on a flat dark background — so ultra-wide cameras show
            // the whole scene (subject never cropped out of frame), with no blown-up zoom.
            ZStack {
                Color.black
                RemoteImage(url: url, contentMode: .fit)
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
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(subtitle)
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
            if let epoch = review.startTime {
                Text(Date(timeIntervalSince1970: epoch).formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .padding(14)
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
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "checkmark")
                .font(.system(size: 16, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
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
