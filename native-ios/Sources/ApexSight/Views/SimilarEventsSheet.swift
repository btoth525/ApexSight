import SwiftUI

struct SimilarEventsSheet: View {
    @EnvironmentObject private var appState: AppState
    let sourceEvent: FrigateEvent
    let events: [FrigateEvent]
    var errorMessage: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()
                if events.isEmpty {
                    // Distinguish a genuine empty result from a fetch/auth error so the
                    // user isn't wrongly told their server lacks embeddings.
                    if let errorMessage {
                        errorState(errorMessage)
                    } else {
                        EmptyStateView(
                            icon: "magnifyingglass",
                            title: "No Similar Events Found",
                            message: "Semantic search found no matches. This requires Frigate semantic search (embeddings) enabled."
                        )
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: GlassTheme.Space.s) {
                            ForEach(events) { event in
                                NavigationLink(destination: EventDetailView(event: event).environmentObject(appState)) {
                                    similarEventRow(event)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(GlassTheme.Space.l)
                    }
                }
            }
            .navigationTitle("Similar Events (\(events.count))")
            .navigationBarTitleDisplayMode(.inline)
            .glassNavBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { Haptics.tap(); dismiss() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(GlassTheme.accent)
                }
            }
        }
    }

    /// A calm error state — distinct from the empty result (orange, semantic warning),
    /// matching EmptyStateView's proportions so the sheet reads consistently.
    private func errorState(_ message: String) -> some View {
        VStack(spacing: GlassTheme.Space.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(GlassTheme.orange)
            Text("Couldn't Load Similar Events")
                .font(.system(.title3).weight(.semibold))
                .foregroundStyle(GlassTheme.primary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(GlassTheme.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(GlassTheme.Space.xl)
    }

    private func similarEventRow(_ event: FrigateEvent) -> some View {
        HStack(spacing: GlassTheme.Space.m) {
            if let url = appState.client?.eventThumbnailURL(id: event.id) {
                RemoteImage(url: url, contentMode: .fill, maxPixelSize: 360)
                    .frame(width: 92, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous)
                    .fill(GlassTheme.surfaceHigh)
                    .frame(width: 92, height: 92)
            }
            VStack(alignment: .leading, spacing: GlassTheme.Space.xs) {
                Text("\(NotificationCopy.emoji(for: event.label, subLabel: event.subLabel)) \(titleize(event.displayLabel))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GlassTheme.primary)
                    .lineLimit(1)
                Text(titleize(event.camera))
                    .font(.footnote)
                    .foregroundStyle(GlassTheme.secondary)
                    .lineLimit(1)
                if let epoch = event.startTime {
                    Text(Date(timeIntervalSince1970: epoch).formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote)
                        .foregroundStyle(GlassTheme.tertiary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(GlassTheme.tertiary)
                .accessibilityHidden(true)
        }
        .padding(GlassTheme.Space.m)
        .background(GlassTheme.surface, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous))
        .cardStroke()
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this event")
    }
}
