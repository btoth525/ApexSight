import SwiftUI

/// Auto-organizes recent events into smart albums (Deliveries, Family, Unknown
/// People, Vehicles, Animals) using labels + your faces/plates — entirely on-device.
struct SmartAlbumsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var albums: [SmartAlbum] = []
    @State private var loading = true
    @State private var path = NavigationPath()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                GlassBackground()
                ScrollView {
                    VStack(spacing: GlassTheme.Space.m) {
                        if loading {
                            ProgressView()
                                .tint(GlassTheme.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 48)
                        } else if albums.isEmpty {
                            EmptyStateView(
                                icon: "square.stack.3d.up.slash",
                                title: "Nothing to organize yet",
                                message: "Recent activity from the last 7 days will be grouped into smart albums here."
                            )
                            .padding(.top, 48)
                        } else {
                            ForEach(albums) { album in
                                Button { path.append(album) } label: { albumCard(album) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(GlassTheme.Space.l)
                }
            }
            .navigationTitle("Smart Albums")
            .navigationBarTitleDisplayMode(.inline)
            .glassNavBar()
            .navigationDestination(for: SmartAlbum.self) { album in
                SmartAlbumDetailView(album: album)
            }
            .navigationDestination(for: FrigateEvent.self) { EventDetailView(event: $0) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .task { await load() }
        }
    }

    private func albumCard(_ album: SmartAlbum) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                GlassTheme.surfaceHigh
                if let hero = album.hero {
                    RemoteImage(url: appState.client?.eventThumbnailURL(id: hero.id))
                } else {
                    Image(systemName: album.icon)
                        .font(.system(size: 40, weight: .regular))
                        .foregroundStyle(GlassTheme.tertiary)
                }
            }
            .frame(height: 132)
            .clipped()

            HStack(spacing: GlassTheme.Space.m) {
                Image(systemName: album.icon)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(GlassTheme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundStyle(GlassTheme.primary)
                    Text("\(album.events.count) \(album.events.count == 1 ? "clip" : "clips")")
                        .font(.subheadline)
                        .foregroundStyle(GlassTheme.secondary)
                }
                Spacer(minLength: GlassTheme.Space.s)
                Image(systemName: "chevron.right")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(GlassTheme.tertiary)
            }
            .padding(GlassTheme.Space.l)
        }
        .background(GlassTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous))
        .cardStroke(GlassTheme.Radius.card)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let client = appState.client else { return }
        let after = Calendar.current.date(byAdding: .day, value: -7, to: Date())
        let events = (try? await client.events(after: after, limit: 400)) ?? []
        albums = AlbumBuilder.build(events: events)
    }
}

private struct SmartAlbumDetailView: View {
    let album: SmartAlbum
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: GlassTheme.Space.s), GridItem(.flexible(), spacing: GlassTheme.Space.s), GridItem(.flexible())], spacing: GlassTheme.Space.s) {
                    ForEach(album.events) { event in
                        NavigationLink(value: event) {
                            RemoteImage(url: appState.client?.eventThumbnailURL(id: event.id))
                                .aspectRatio(1, contentMode: .fill)
                                .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
                                .cardStroke(GlassTheme.Radius.tile)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(GlassTheme.Space.l)
            }
        }
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
    }
}

// MARK: - Model + builder

struct SmartAlbum: Identifiable, Hashable {
    let id: String          // album key, stable
    let name: String
    let icon: String
    let tint: Color
    let events: [FrigateEvent]

    var hero: FrigateEvent? { events.first }

    static func == (lhs: SmartAlbum, rhs: SmartAlbum) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum AlbumBuilder {
    private static let carriers: Set<String> = ["amazon", "ups", "fedex", "usps", "dhl", "mail", "mail carrier"]
    private static let vehicles: Set<String> = ["car", "truck", "motorcycle", "bus", "bicycle"]
    private static let animals: Set<String> = ["dog", "cat", "bird", "deer", "bear", "squirrel", "rabbit", "fox", "raccoon", "horse"]

    static func build(events: [FrigateEvent]) -> [SmartAlbum] {
        var deliveries: [FrigateEvent] = []
        var family: [FrigateEvent] = []
        var unknown: [FrigateEvent] = []
        var vehicleEvents: [FrigateEvent] = []
        var animalEvents: [FrigateEvent] = []

        for event in events.sorted(by: { ($0.startTime ?? 0) > ($1.startTime ?? 0) }) {
            let label = event.label.lowercased()
            let sub = (event.subLabel ?? "").lowercased()
            if label == "package" || carriers.contains(sub) {
                deliveries.append(event)
            } else if label == "person" {
                if event.recognizedFace != nil { family.append(event) } else { unknown.append(event) }
            } else if vehicles.contains(label) {
                vehicleEvents.append(event)
            } else if animals.contains(label) {
                animalEvents.append(event)
            }
        }

        let candidates: [SmartAlbum] = [
            SmartAlbum(id: "deliveries", name: "Deliveries", icon: "shippingbox.fill", tint: GlassTheme.orange, events: deliveries),
            SmartAlbum(id: "family", name: "Family & Known", icon: "person.2.fill", tint: GlassTheme.green, events: family),
            SmartAlbum(id: "unknown", name: "Unknown People", icon: "person.fill.questionmark", tint: GlassTheme.red, events: unknown),
            SmartAlbum(id: "vehicles", name: "Vehicles", icon: "car.fill", tint: GlassTheme.blue, events: vehicleEvents),
            SmartAlbum(id: "animals", name: "Animals", icon: "pawprint.fill", tint: GlassTheme.purple, events: animalEvents),
        ]
        return candidates.filter { !$0.events.isEmpty }
    }
}
