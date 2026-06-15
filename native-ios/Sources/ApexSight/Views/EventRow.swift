import SwiftUI

struct EventRow: View {
    @EnvironmentObject private var appState: AppState
    let event: FrigateEvent

    var body: some View {
        HStack(spacing: 12) {
            if let url = appState.client?.eventThumbnailURL(id: event.id) {
                RemoteImage(url: url)
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("\(NotificationCopy.emoji(for: event.label, subLabel: event.subLabel)) \(titleize(event.displayLabel))")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(GlassTheme.primary)
                Text("\(titleize(event.camera)) · \(relativeTime(event.startTime))")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(GlassTheme.secondary)
                HStack(spacing: 8) {
                    if let score = event.score ?? event.topScore {
                        Text("\(Int(score * 100))% confidence")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(GlassTheme.tertiary)
                    }
                    if let plate = event.recognizedLicensePlate, !plate.isEmpty {
                        chip("🔎 \(plate.uppercased())", tint: GlassTheme.purple)
                    } else if let sub = event.subLabel, !sub.isEmpty {
                        chip(titleize(sub), tint: GlassTheme.cyan)
                    }
                }
                if let epoch = event.startTime {
                    Text(Date(timeIntervalSince1970: epoch).formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(GlassTheme.tertiary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(GlassTheme.tertiary)
        }
        .padding(10)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .black))
            .foregroundStyle(tint)
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
