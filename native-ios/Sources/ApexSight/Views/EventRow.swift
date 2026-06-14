import SwiftUI

struct EventRow: View {
    @EnvironmentObject private var appState: AppState
    let event: FrigateEvent

    var body: some View {
        HStack(spacing: 12) {
            if let url = appState.client?.eventSnapshotURL(id: event.id) {
                RemoteImage(url: url)
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(titleize(event.label))
                    .font(.system(size: 16, weight: .900))
                    .foregroundStyle(GlassTheme.primary)
                Text("\(titleize(event.camera)) - \(relativeTime(event.startTime))")
                    .font(.system(size: 13, weight: .700))
                    .foregroundStyle(GlassTheme.secondary)
                if let score = event.score ?? event.topScore {
                    Text("\(Int(score * 100))% confidence")
                        .font(.system(size: 12, weight: .700))
                        .foregroundStyle(GlassTheme.tertiary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .900))
                .foregroundStyle(GlassTheme.tertiary)
        }
        .padding(10)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
