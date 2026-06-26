import SwiftUI

/// Auto-organizes recent events into smart albums (Deliveries, Family, Unknown
/// People, Vehicles, Animals) using labels + your faces/plates — entirely on-device.
struct SmartAlbumsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var albums: [SmartAlbum] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var path = NavigationPath()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                GlassBackground()
                ScrollView {
                    VStack(spacing: GlassTheme.Space.m) {
                        if loading {
                            // Album-card skeletons (hero + title row) so the gallery shape
                            // is visible immediately rather than a centered spinner.
                            albumsSkeleton
                                .transition(.opacity)
                        } else if let error = errorMessage {
                            errorState(error)
                                .transition(.opacity)
                        } else if albums.isEmpty {
                            EmptyStateView(
                                icon: "square.stack.3d.up.slash",
                                title: "Nothing to organize yet",
                                message: "Recent activity from the last 7 days will be grouped into smart albums here."
                            )
                            .padding(.top, 48)
                            .transition(.opacity)
                        } else {
                            ForEach(albums) { album in
                                Button { Haptics.tap(); path.append(album) } label: { albumCard(album) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(album.name), \(album.events.count) \(album.events.count == 1 ? "clip" : "clips")")
                            }
                        }
                    }
                    .padding(GlassTheme.Space.l)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: loading)
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
                ToolbarItem(placement: .cancellationAction) { Button("Done") { Haptics.tap(); dismiss() } }
            }
            .task { await load() }
        }
    }

    /// A stack of album-card skeletons that mirror the real cards' hero + title row.
    private var albumsSkeleton: some View {
        VStack(spacing: GlassTheme.Space.m) {
            ForEach(0..<4, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 0) {
                    SkeletonBlock(cornerRadius: 0)
                        .frame(height: 132)
                    HStack(spacing: GlassTheme.Space.m) {
                        SkeletonBlock(cornerRadius: 6).frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
                            SkeletonBlock(cornerRadius: 6).frame(width: 140, height: 16)
                            SkeletonBlock(cornerRadius: 6).frame(width: 60, height: 12)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(GlassTheme.Space.l)
                }
                .background(GlassTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous))
                .cardStroke(GlassTheme.Radius.card)
            }
        }
        .accessibilityHidden(true)
    }

    /// Fetch failed — explain it and offer a retry, never a silent empty gallery.
    private func errorState(_ message: String) -> some View {
        VStack(spacing: GlassTheme.Space.m) {
            EmptyStateView(
                icon: "exclamationmark.triangle",
                title: "Couldn't load albums",
                message: message
            )
            Button {
                Haptics.tap()
                Task { await load() }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    private func albumCard(_ album: SmartAlbum) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                GlassTheme.surfaceHigh
                if let hero = album.hero {
                    // Full-width 132pt hero — cap the decode rather than holding a 4K frame.
                    RemoteImage(url: appState.client?.eventThumbnailURL(id: hero.id), maxPixelSize: 600)
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
        errorMessage = nil
        defer { loading = false }
        guard let client = appState.client else { return }
        let after = Calendar.current.date(byAdding: .day, value: -7, to: Date())
        do {
            // A thrown fetch error now surfaces a retryable error state instead of
            // silently presenting an empty gallery.
            let events = try await client.events(after: after, limit: 400)
            albums = AlbumBuilder.build(events: events)
        } catch {
            errorMessage = error.localizedDescription
            albums = []
            Haptics.error()
        }
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
                            // 3-up grid tile — downsample instead of decoding the full frame.
                            RemoteImage(url: appState.client?.eventThumbnailURL(id: event.id), maxPixelSize: 360)
                                .aspectRatio(1, contentMode: .fill)
                                .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
                                .cardStroke(GlassTheme.Radius.tile)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded { Haptics.tap() })
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
