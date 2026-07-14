import SwiftUI

/// Browse the exports Frigate holds — re-download, share, save to Photos, rename, or delete.
/// (Frigate renders these server-side, so they persist on the host until you remove them.)
@MainActor   // its async actions mutate @State (busyID/toast/exports/…); pin them to the main actor
struct MyExportsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var exporter = ExportManager()

    @State private var exports: [FrigateExport] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var sharePayload: SharePayload?
    @State private var busyID: String?
    @State private var renaming: FrigateExport?
    @State private var renameText = ""
    @State private var pendingDelete: FrigateExport?
    @State private var toast: String?
    /// True when `toast` reports a failure, so the pill shows red instead of success-green.
    @State private var toastIsError = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: GlassTheme.Space.m) {
                if isLoading && exports.isEmpty {
                    SkeletonList(rows: 6)
                        .padding(.top, GlassTheme.Space.s)
                } else if exports.isEmpty {
                    ContentUnavailableView("No exports", systemImage: "film.stack",
                        description: Text(errorText ?? "Clips you export show up here."))
                        .padding(.top, 80)
                } else {
                    ForEach(exports) { export in
                        row(export)
                    }
                }
            }
            .padding(GlassTheme.Space.m)
        }
        .background(GlassTheme.background.ignoresSafeArea())
        .navigationTitle("My Exports")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $sharePayload) { ShareSheet(items: $0.items) }
        .alert("Rename export", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { Task { await commitRename() } }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete this export?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await commitDelete() } }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { Text("Removes it from Frigate. This can't be undone.") }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, GlassTheme.Space.l).padding(.vertical, GlassTheme.Space.s)
                    .background((toastIsError ? GlassTheme.red : GlassTheme.green).opacity(0.92), in: Capsule())
                    .padding(.bottom, 40).transition(.opacity)
            }
        }
    }

    private func row(_ export: FrigateExport) -> some View {
        GlassCard {
            HStack(spacing: GlassTheme.Space.m) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(GlassTheme.surfaceHigh)
                    Image(systemName: export.isReady ? "film.fill" : "hourglass")
                        .font(.title3).foregroundStyle(export.isReady ? GlassTheme.accent : GlassTheme.orange)
                }
                .frame(width: 60, height: 60)

                VStack(alignment: .leading, spacing: 3) {
                    Text(export.name).font(.subheadline.weight(.semibold)).foregroundStyle(GlassTheme.primary).lineLimit(2)
                    Text(export.camera.replacingOccurrences(of: "_", with: " "))
                        .font(.caption).foregroundStyle(GlassTheme.secondary)
                    if !export.isReady {
                        Label("Rendering…", systemImage: "gearshape.2.fill").font(.caption2).foregroundStyle(GlassTheme.orange)
                    } else if let d = export.createdAt {
                        Text(d.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(GlassTheme.tertiary)
                    }
                }
                Spacer(minLength: 0)

                if busyID == export.id {
                    ProgressView().tint(GlassTheme.accent)
                } else if export.isReady {
                    Menu {
                        Button { Task { await share(export) } } label: { Label("Share", systemImage: "square.and.arrow.up") }
                        Button { Task { await save(export) } } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                        Button { renaming = export; renameText = export.name } label: { Label("Rename", systemImage: "pencil") }
                        Divider()
                        Button(role: .destructive) { pendingDelete = export } label: { Label("Delete", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle.fill").font(.title3).foregroundStyle(GlassTheme.secondary)
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func load() async {
        guard let client = appState.client else { errorText = "Not connected."; isLoading = false; return }
        do { exports = try await client.exports(); errorText = nil }
        catch { errorText = (error as? LocalizedError)?.errorDescription ?? "Couldn't load exports." }
        isLoading = false
    }

    private func downloadURL(_ export: FrigateExport) async -> URL? {
        guard let client = appState.client, let filename = export.filename else { return nil }
        busyID = export.id; defer { busyID = nil }
        return try? await client.downloadClipFile(from: client.exportFileURL(filename: filename), suggestedName: filename)
    }

    private func share(_ export: FrigateExport) async {
        if let url = await downloadURL(export) { sharePayload = SharePayload(url: url) }
        else { flash("Download failed", isError: true) }
    }

    private func save(_ export: FrigateExport) async {
        guard let url = await downloadURL(export) else { flash("Download failed", isError: true); return }
        let failed = await exporter.saveToPhotos([url])
        if case .failed(let m) = exporter.phase { flash(m, isError: true) }
        else if failed.isEmpty { flash("Saved to Photos ✓") }
        else {
            // Photos refused it (ultra-wide clip) — share it so it can still be saved to Files.
            flash("Photos can't import this clip — opening Share")
            sharePayload = SharePayload(urls: failed)
        }
    }

    private func commitRename() async {
        guard let export = renaming, let client = appState.client else { return }
        let newName = renameText.trimmingCharacters(in: .whitespaces)
        renaming = nil
        guard !newName.isEmpty else { return }
        busyID = export.id
        defer { busyID = nil }
        do {
            try await client.renameExport(id: export.id, name: newName)
            await load()
        } catch {
            flash("Couldn't rename — try again", isError: true)
        }
    }

    private func commitDelete() async {
        guard let export = pendingDelete, let client = appState.client else { return }
        pendingDelete = nil
        busyID = export.id
        defer { busyID = nil }
        do {
            try await client.deleteExport(id: export.id)
            // Only drop the row once the server confirms — removing it on a failed delete would
            // hide the export until the next reload, when it silently reappears.
            exports.removeAll { $0.id == export.id }
        } catch {
            flash("Couldn't delete — try again", isError: true)
        }
    }

    private func flash(_ text: String, isError: Bool = false) {
        toastIsError = isError
        withAnimation { toast = text }
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); withAnimation { toast = nil } }
    }
}
