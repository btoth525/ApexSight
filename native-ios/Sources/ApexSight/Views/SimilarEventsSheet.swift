import SwiftUI

struct SimilarEventsSheet: View {
    @EnvironmentObject private var appState: AppState
    let sourceEvent: FrigateEvent
    let events: [FrigateEvent]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()
                if events.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "magnifyingglass.circle")
                            .font(.system(size: 44, weight: .black))
                            .foregroundStyle(GlassTheme.secondary)
                        Text("No Similar Events Found")
                            .font(.system(size: 20, weight: .black))
                            .foregroundStyle(GlassTheme.primary)
                        Text("Semantic search found no matches. This requires Frigate+ with embeddings enabled.")
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(GlassTheme.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(events) { event in
                                NavigationLink(destination: EventDetailView(event: event).environmentObject(appState)) {
                                    similarEventRow(event)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Similar Events (\(events.count))")
            .navigationBarTitleDisplayMode(.inline)
            .glassNavBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(GlassTheme.cyan)
                }
            }
        }
    }

    private func similarEventRow(_ event: FrigateEvent) -> some View {
        HStack(spacing: 12) {
            if let url = appState.client?.eventThumbnailURL(id: event.id) {
                RemoteImage(url: url)
                    .frame(width: 64, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black)
                    .frame(width: 64, height: 48)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(NotificationCopy.emoji(for: event.label, subLabel: event.subLabel)) \(titleize(event.displayLabel))")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(GlassTheme.primary)
                Text(titleize(event.camera))
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(GlassTheme.secondary)
                if let epoch = event.startTime {
                    Text(Date(timeIntervalSince1970: epoch).formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(GlassTheme.tertiary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(GlassTheme.tertiary)
        }
        .padding(12)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
