import SwiftUI

struct EventRow: View {
    @EnvironmentObject private var appState: AppState
    let event: FrigateEvent

    /// Frigate keeps upgrading an event's thumbnail to the best frame while it's live (and
    /// finalizes it at the end) — so revalidate the cached image during the event and for a
    /// short window after, instead of forever showing the first (often subject-less) fetch.
    private var thumbnailStillChanging: Bool {
        guard let end = event.endTime else { return true }   // in progress
        return Date().timeIntervalSince1970 - end < 120       // just finished — grab the final frame
    }

    var body: some View {
        HStack(spacing: 12) {
            if let url = appState.client?.eventThumbnailURL(id: event.id) {
                // 110pt cell — decode to ~3x, not the 1000px default (≈9x the pixels shown).
                RemoteImage(url: url, contentMode: .fill, maxPixelSize: 360,
                            revalidate: thumbnailStillChanging)
                .frame(width: 110, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 5) {
                // Object in the title; the sub-label/plate shows as a chip below, so the
                // recognized name isn't printed twice (displayLabel == subLabel otherwise).
                // Semantic fonts (capped) so the row scales with Dynamic Type without breaking
                // the fixed-height thumbnail layout at the largest accessibility sizes.
                Text("\(NotificationCopy.emoji(for: event.label, subLabel: event.subLabel)) \(titleize(event.label))")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(GlassTheme.primary)
                    .lineLimit(1)
                Text("\(titleize(event.camera)) · \(relativeTime(event.startTime))")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(GlassTheme.secondary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let score = event.score ?? event.topScore {
                        Text("\(Int(score * 100))% confidence")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(GlassTheme.tertiary)
                            .lineLimit(1)
                    }
                    if let plate = event.recognizedLicensePlate, !plate.isEmpty {
                        chip("🔎 \(plate.uppercased())", tint: GlassTheme.purple)
                    } else if let face = event.recognizedFace {
                        // A recognized person reads cleaner as a face chip than a bare name.
                        chip("👤 \(titleize(face))", tint: GlassTheme.cyan)
                    } else if let sub = event.subLabel, !sub.isEmpty {
                        chip(titleize(sub), tint: GlassTheme.cyan)
                    }
                }
                if let epoch = event.startTime {
                    Text(Date(timeIntervalSince1970: epoch).formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(GlassTheme.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.black))
                .foregroundStyle(GlassTheme.tertiary)
        }
        .padding(10)
        .background(GlassTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .cardStroke(20)
        .accessibilityElement(children: .combine)
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.black))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }

    private func relativeTime(_ epoch: Double?) -> String {
        guard let epoch else { return "Now" }
        let seconds = max(0, Int(Date().timeIntervalSince1970 - epoch))
        if seconds < 60 { return "Now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}
