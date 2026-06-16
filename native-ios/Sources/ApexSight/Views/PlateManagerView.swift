import SwiftUI

/// Name your license plates so alerts read "Brandon's Car" instead of a raw plate,
/// and anything unknown reads "Unknown plate." App-managed (Frigate has no plate
/// API) and synced to the relay so it shapes app-closed pushes too.
struct PlateManagerView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var store = NotificationStyleStore()

    @State private var editing: KnownPlate?
    @State private var showEditor = false
    @State private var recent: [RecentPlate] = []
    @State private var loadingRecent = true

    struct RecentPlate: Identifiable {
        let id = UUID()
        let plate: String
        let camera: String
        let when: Date
    }

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(spacing: 16) {
                    explainer
                    knownCard
                    recentCard
                }
                .padding(16)
            }
        }
        .navigationTitle("License Plates")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    editing = nil
                    showEditor = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(GlassTheme.cyan)
                }
                .accessibilityLabel("Add a plate")
            }
        }
        .sheet(isPresented: $showEditor) {
            PlateEditorSheet(existing: editing) { result in
                upsert(result)
            }
        }
        .task { await loadRecent() }
    }

    private var s: NotificationStyle { store.style }

    // MARK: - Cards

    private var explainer: some View {
        GlassCard {
            HStack(spacing: 12) {
                Image(systemName: "car.fill")
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(GlassTheme.cyan)
                    .frame(width: 44, height: 44)
                    .background(GlassTheme.cyan.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("Name the plates you know. Matches are tolerant of spaces and dashes, and apply to your notifications too.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GlassTheme.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    private var knownCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your Plates")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(GlassTheme.primary)

                if s.knownPlates.isEmpty {
                    Text("No plates named yet. Tap ＋ or pick one from \"Recently seen\" below.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(GlassTheme.tertiary)
                } else {
                    ForEach(s.knownPlates) { plate in
                        Button {
                            editing = plate
                            showEditor = true
                        } label: {
                            plateRow(plate)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func plateRow(_ plate: KnownPlate) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(GlassTheme.green)
            VStack(alignment: .leading, spacing: 5) {
                Text(plate.name)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(GlassTheme.primary)
                    .lineLimit(1)
                FlowChips(plate.plates)
            }
            Spacer(minLength: 0)
            Button(role: .destructive) {
                store.style.knownPlates.removeAll { $0.id == plate.id }
            } label: {
                Image(systemName: "trash.fill")
                    .foregroundStyle(GlassTheme.red)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(plate.name)")
        }
        .padding(12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var recentCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recently Seen")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(GlassTheme.primary)

                if loadingRecent {
                    ProgressView().tint(GlassTheme.cyan)
                } else if recent.isEmpty {
                    Text("No unrecognized plates lately. New ones will show here to name in a tap.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(GlassTheme.tertiary)
                } else {
                    ForEach(recent) { item in
                        HStack(spacing: 12) {
                            Text(item.plate)
                                .font(.system(size: 14, weight: .black, design: .monospaced))
                                .foregroundStyle(GlassTheme.primary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(titleize(item.camera))
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(GlassTheme.secondary)
                                Text(item.when, style: .relative)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(GlassTheme.tertiary)
                            }
                            Spacer(minLength: 0)
                            Button {
                                editing = KnownPlate(name: "", plates: [item.plate])
                                showEditor = true
                            } label: {
                                Text("Name it")
                                    .font(.system(size: 12, weight: .heavy))
                            }
                            .buttonStyle(PillButtonStyle(tint: GlassTheme.blue))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Logic

    private func upsert(_ plate: KnownPlate) {
        let clean = KnownPlate(
            id: plate.id,
            name: plate.name.trimmingCharacters(in: .whitespaces),
            plates: plate.plates.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        )
        guard !clean.name.isEmpty, !clean.plates.isEmpty else { return }
        if let idx = store.style.knownPlates.firstIndex(where: { $0.id == clean.id }) {
            store.style.knownPlates[idx] = clean
        } else {
            store.style.knownPlates.append(clean)
        }
        Task { await loadRecent() }
    }

    private func loadRecent() async {
        loadingRecent = true
        defer { loadingRecent = false }
        guard let client = appState.client else { return }
        let events = (try? await client.events(limit: 100)) ?? []
        var seen = Set<String>()
        var out: [RecentPlate] = []
        for event in events {
            guard let plate = event.recognizedLicensePlate, !plate.isEmpty else { continue }
            guard store.style.knownPlateName(for: plate) == nil else { continue }
            let norm = NotificationStyle.normalizePlate(plate)
            guard !norm.isEmpty, !seen.contains(norm) else { continue }
            seen.insert(norm)
            out.append(RecentPlate(
                plate: plate,
                camera: event.camera,
                when: Date(timeIntervalSince1970: event.startTime ?? Date().timeIntervalSince1970)
            ))
        }
        recent = Array(out.prefix(12))
    }
}

// MARK: - Editor sheet

private struct PlateEditorSheet: View {
    let existing: KnownPlate?
    let onSave: (KnownPlate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var plates: [String]

    init(existing: KnownPlate?, onSave: @escaping (KnownPlate) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _plates = State(initialValue: existing?.plates.isEmpty == false ? existing!.plates : [""])
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Name")
                                    .font(.system(size: 13, weight: .black))
                                    .foregroundStyle(GlassTheme.tertiary)
                                TextField("e.g. Brandon's Car", text: $name)
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(GlassTheme.primary)
                                    .padding(12)
                                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                        GlassCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Plates")
                                    .font(.system(size: 13, weight: .black))
                                    .foregroundStyle(GlassTheme.tertiary)
                                ForEach(plates.indices, id: \.self) { idx in
                                    HStack(spacing: 8) {
                                        TextField("ABC-1234", text: $plates[idx])
                                            .textInputAutocapitalization(.characters)
                                            .autocorrectionDisabled()
                                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                                            .foregroundStyle(GlassTheme.primary)
                                            .padding(12)
                                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        if plates.count > 1 {
                                            Button {
                                                plates.remove(at: idx)
                                            } label: {
                                                Image(systemName: "minus.circle.fill").foregroundStyle(GlassTheme.red)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                                Button {
                                    plates.append("")
                                } label: {
                                    Label("Add another plate", systemImage: "plus")
                                        .font(.system(size: 13, weight: .heavy))
                                        .foregroundStyle(GlassTheme.cyan)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle(existing?.name.isEmpty == false ? "Edit Plate" : "New Plate")
            .navigationBarTitleDisplayMode(.inline)
            .glassNavBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(KnownPlate(id: existing?.id ?? UUID().uuidString, name: name, plates: plates))
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty ||
                              plates.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                }
            }
        }
    }
}

// MARK: - Small flow-layout of plate chips

private struct FlowChips: View {
    let items: [String]
    init(_ items: [String]) { self.items = items }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items.prefix(4), id: \.self) { plate in
                Text(plate)
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .foregroundStyle(GlassTheme.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.08), in: Capsule())
            }
            if items.count > 4 {
                Text("+\(items.count - 4)")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(GlassTheme.tertiary)
            }
        }
    }
}
