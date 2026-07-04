import SwiftUI
import AVKit

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
                            Label("\(incident.significantCameras.count)", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
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
    @StateObject private var stitch = IncidentPlayerModel()
    let incident: Incident

    @State private var sharePayload: SharePayload?
    @State private var showSavedToast = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                stitchedPlayer
                header
                filmstrip
            }
            .padding(GlassTheme.Space.m)
            .padding(.bottom, 120)
        }
        .background(GlassTheme.background.ignoresSafeArea())
        .navigationTitle("Incident")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .safeAreaInset(edge: .bottom) { exportBar }
        .onAppear {
            if let client = appState.client { stitch.configure(legs: incident.events, client: client) }
        }
        .onDisappear { stitch.teardown() }
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
                Label("Tracked across \(incident.significantCameras.count) cameras", systemImage: "point.topleft.down.to.point.bottomright.curvepath.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GlassTheme.accent)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The whole incident played back-to-back as one reel.
    private var stitchedPlayer: some View {
        VideoPlayer(player: stitch.player)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
            .overlay(alignment: .topLeading) {
                // Which camera is on screen right now.
                if incident.events.indices.contains(stitch.currentIndex) {
                    let cam = incident.events[stitch.currentIndex].camera
                    Label(prettyCamera(cam), systemImage: "video.fill")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(10)
                }
            }
    }

    /// HomeKit-style strip of the segments below the player: tap to jump, current one highlighted.
    private var filmstrip: some View {
        VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
            SectionHeader("\(incident.events.count) clips · plays as one")
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: GlassTheme.Space.s) {
                        ForEach(Array(incident.events.enumerated()), id: \.element.id) { idx, event in
                            segmentCell(event, index: idx)
                                .id(idx)
                                .onTapGesture { Haptics.select(); stitch.jump(to: idx) }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .onChange(of: stitch.currentIndex) { _, idx in
                    withAnimation { proxy.scrollTo(idx, anchor: .center) }
                }
            }
        }
    }

    private func segmentCell(_ event: FrigateEvent, index: Int) -> some View {
        let isCurrent = index == stitch.currentIndex
        return VStack(alignment: .leading, spacing: 4) {
            RemoteImage(url: appState.client?.eventSnapshotURL(id: event.id), maxPixelSize: 300)
                .frame(width: 132, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isCurrent ? GlassTheme.accent : .clear, lineWidth: 2.5))
                .overlay(alignment: .bottomTrailing) {
                    if isCurrent {
                        Image(systemName: "play.fill").font(.system(size: 9, weight: .black))
                            .padding(4).background(GlassTheme.accent, in: Circle()).foregroundStyle(.black).padding(5)
                    }
                }
            Text(prettyCamera(event.camera)).font(.caption2.weight(.semibold))
                .foregroundStyle(isCurrent ? GlassTheme.primary : GlassTheme.secondary).lineLimit(1)
            if let s = event.startTime {
                Text(Date(timeIntervalSince1970: s).formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10)).foregroundStyle(GlassTheme.tertiary)
            }
        }
        .frame(width: 132)
    }

    // MARK: Export bar

    private var exportBar: some View {
        VStack(spacing: 8) {
            switch exporter.phase {
            case .rendering(let done, let total):
                progressBar(label: total > 1 ? "Preparing clip \(min(done + 1, total)) of \(total)…" : "Preparing on Frigate…",
                            value: nil)
            case .downloading(let progress):
                progressBar(label: "Downloading… \(Int(progress * 100))%", value: progress)
            case .saving:
                progressBar(label: "Saving to Photos…", value: nil)
            case .failed(let msg):
                Text(msg).font(.caption).foregroundStyle(GlassTheme.orange).multilineTextAlignment(.center)
                exportButton
            case .finished(let urls):
                HStack(spacing: GlassTheme.Space.m) {
                    Button { sharePayload = SharePayload(urls: urls) } label: {
                        Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }.buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
                    Button {
                        Task { await exporter.saveToPhotos(urls); if case .finished = exporter.phase { flashSaved() } }
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

    /// HomeKit-style live progress: a filling bar with a percentage (determinate) or a sweep
    /// (indeterminate, while Frigate renders).
    private func progressBar(label: String, value: Double?) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(GlassTheme.secondary)
                Spacer()
                if value == nil { ProgressView().tint(GlassTheme.accent).scaleEffect(0.8) }
            }
            ProgressView(value: value, total: 1.0)
                .progressViewStyle(.linear)
                .tint(GlassTheme.accent)
                .animation(.easeOut(duration: 0.2), value: value)
        }
        .padding(.vertical, 2)
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
            Label(incident.exportCameras.count > 1 ? "Export \(incident.exportCameras.count) clips" : "Export clip",
                  systemImage: "film.stack").frame(maxWidth: .infinity)
        }
        .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
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
