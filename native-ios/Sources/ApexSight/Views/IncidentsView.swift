import SwiftUI

// Navigation routes so Incidents/My-Exports push inside the Activity tab's existing stack.
struct IncidentsRoute: Hashable {}
struct MyExportsRoute: Hashable {}

private func prettyCamera(_ name: String) -> String {
    name.replacingOccurrences(of: "_", with: " ")
}

// MARK: - List

/// Clusters recent events into "incidents" (stories) and lists them. A single-camera burst becomes
/// one incident; a subject crossing cameras shows its path. Each is one-tap exportable.
struct IncidentsListView: View {
    @EnvironmentObject private var appState: AppState

    private var incidents: [Incident] {
        IncidentBuilder.build(from: appState.events)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: GlassTheme.Space.m) {
                if incidents.isEmpty {
                    ContentUnavailableView("No incidents yet",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text("Recent activity gets grouped into stories here."))
                        .padding(.top, 80)
                } else {
                    ForEach(incidents) { incident in
                        NavigationLink(value: incident) {
                            IncidentCard(incident: incident)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(GlassTheme.Space.m)
        }
        .background(GlassTheme.background.ignoresSafeArea())
        .navigationTitle("Incidents")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink(value: MyExportsRoute()) {
                    Label("Exports", systemImage: "square.and.arrow.up.on.square")
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }
}

private struct IncidentCard: View {
    @EnvironmentObject private var appState: AppState
    let incident: Incident

    var body: some View {
        GlassCard {
            HStack(spacing: GlassTheme.Space.m) {
                RemoteImage(url: appState.client?.eventSnapshotURL(id: incident.thumbnailEvent.id), maxPixelSize: 400)
                    .frame(width: 92, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if incident.isCrossCamera {
                            Label("\(incident.cameraPath.count)", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                                .font(.system(size: 10, weight: .black))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(GlassTheme.accent, in: Capsule())
                                .foregroundStyle(.black)
                                .padding(6)
                        }
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(prettyCamera(incident.headline).capitalized)
                        .font(.headline).foregroundStyle(GlassTheme.primary).lineLimit(1)
                    // Camera path: A → B → C
                    HStack(spacing: 4) {
                        ForEach(Array(incident.cameraPath.prefix(3).enumerated()), id: \.offset) { idx, cam in
                            if idx > 0 { Image(systemName: "chevron.compact.right").font(.caption2).foregroundStyle(GlassTheme.tertiary) }
                            Text(prettyCamera(cam))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(GlassTheme.secondary)
                                .lineLimit(1)
                        }
                    }
                    HStack(spacing: GlassTheme.Space.s) {
                        Label(incident.startDate.formatted(date: .omitted, time: .shortened),
                              systemImage: "clock").labelStyle(.titleAndIcon)
                        Text("· \(incident.events.count) event\(incident.events.count == 1 ? "" : "s")")
                    }
                    .font(.caption2).foregroundStyle(GlassTheme.tertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(GlassTheme.tertiary)
            }
        }
    }
}

// MARK: - Detail

struct IncidentDetailView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var exporter = ExportManager()
    let incident: Incident

    @State private var sharePayload: SharePayload?
    @State private var showSavedToast = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                header
                pathTimeline
            }
            .padding(GlassTheme.Space.m)
            .padding(.bottom, 120)
        }
        .background(GlassTheme.background.ignoresSafeArea())
        .navigationTitle("Incident")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .safeAreaInset(edge: .bottom) { exportBar }
        .sheet(item: $sharePayload) { ShareSheet(items: $0.items) }
        .overlay(alignment: .bottom) {
            if showSavedToast {
                Text("Saved to Photos ✓")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, GlassTheme.Space.l).padding(.vertical, GlassTheme.Space.s)
                    .background(GlassTheme.green.opacity(0.92), in: Capsule())
                    .padding(.bottom, 96)
                    .transition(.opacity)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
            Text(prettyCamera(incident.headline).capitalized)
                .font(.title2.bold()).foregroundStyle(GlassTheme.primary)
            Text("\(incident.startDate.formatted(date: .abbreviated, time: .shortened)) · \(Self.durationText(incident.duration))")
                .font(.subheadline).foregroundStyle(GlassTheme.secondary)
            if incident.isCrossCamera {
                Label("Tracked across \(incident.cameraPath.count) cameras", systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GlassTheme.accent)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The story as a vertical timeline of legs (one per event), tappable into the clip.
    private var pathTimeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Timeline")
                .padding(.bottom, GlassTheme.Space.s)
            ForEach(Array(incident.events.enumerated()), id: \.element.id) { idx, event in
                NavigationLink(value: event) {
                    legRow(event, isLast: idx == incident.events.count - 1)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func legRow(_ event: FrigateEvent, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: GlassTheme.Space.m) {
            VStack(spacing: 0) {
                Circle().fill(event.label == "person" ? GlassTheme.orange : GlassTheme.accent)
                    .frame(width: 11, height: 11)
                if !isLast { Rectangle().fill(GlassTheme.separator).frame(width: 2).frame(maxHeight: .infinity) }
            }
            .frame(width: 11)

            RemoteImage(url: appState.client?.eventSnapshotURL(id: event.id), maxPixelSize: 300)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(event.displayLabel.capitalized).font(.subheadline.weight(.semibold)).foregroundStyle(GlassTheme.primary)
                Text(prettyCamera(event.camera)).font(.caption).foregroundStyle(GlassTheme.secondary)
                if let s = event.startTime {
                    Text(Date(timeIntervalSince1970: s).formatted(date: .omitted, time: .standard))
                        .font(.caption2).foregroundStyle(GlassTheme.tertiary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "play.circle.fill").font(.title3).foregroundStyle(GlassTheme.accent.opacity(0.85))
        }
        .padding(.bottom, GlassTheme.Space.m)
    }

    // MARK: Export bar

    private var exportBar: some View {
        VStack(spacing: 6) {
            switch exporter.phase {
            case .rendering(let done, let total):
                progressRow("Rendering on Frigate… \(done)/\(total)")
            case .downloading:
                progressRow("Downloading…")
            case .failed(let msg):
                Text(msg).font(.caption).foregroundStyle(GlassTheme.orange).multilineTextAlignment(.center)
                exportButton
            case .finished(let urls):
                HStack(spacing: GlassTheme.Space.m) {
                    Button { sharePayload = SharePayload(urls: urls) } label: {
                        Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }.buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
                    Button {
                        Task { await exporter.saveToPhotos(urls); flashSaved() }
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }.buttonStyle(PillButtonStyle(tint: GlassTheme.surfaceHigh))
                }
            default:
                exportButton
            }
        }
        .padding(GlassTheme.Space.m)
        .background(.ultraThinMaterial)
    }

    private var exportButton: some View {
        Button {
            let windows = incident.exportWindows().map {
                ExportManager.Window(camera: $0.camera, start: $0.start, end: $0.end)
            }
            let name = "\(prettyCamera(incident.headline).capitalized) \(incident.startDate.formatted(date: .numeric, time: .shortened))"
            Task {
                guard let client = appState.client else { return }
                Haptics.tap()
                await exporter.export(windows: windows, name: name, client: client)
            }
        } label: {
            Label(incident.isCrossCamera ? "Export \(incident.cameraPath.count) clips" : "Export clip",
                  systemImage: "film.stack").frame(maxWidth: .infinity)
        }
        .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: GlassTheme.Space.s) {
            ProgressView().tint(GlassTheme.accent)
            Text(text).font(.subheadline.weight(.medium)).foregroundStyle(GlassTheme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private func flashSaved() {
        withAnimation { showSavedToast = true }
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); withAnimation { showSavedToast = false } }
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }
}

extension SharePayload {
    /// Share one or many downloaded clips at once.
    init(urls: [URL]) { items = urls }
}
