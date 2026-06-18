import SwiftUI

/// Manage Frigate's face library from the app: see your known people, and assign
/// recently-detected faces to a person so future alerts say "Alex arrived"
/// instead of "person". Drives Frigate's /api/faces endpoints (0.16+).
struct FaceManagerView: View {
    @EnvironmentObject private var appState: AppState

    @State private var faces: [String: [String]] = [:]
    @State private var recentPeople: [FrigateEvent] = []
    @State private var available = true
    @State private var loading = true

    @State private var assigning: FrigateEvent?
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var showAddPerson = false
    @State private var newPersonName = ""
    @State private var toast: String?
    @State private var toastIsError = false

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(spacing: 16) {
                    if !available {
                        unavailableCard
                    } else {
                        explainer
                        peopleCard
                        trainCard
                    }
                }
                .padding(16)
            }
            if let toast {
                ToastBanner(text: toast, isError: toastIsError)
            }
        }
        .navigationTitle("People & Faces")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showAddPerson = true } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(GlassTheme.cyan)
                }
                .accessibilityLabel("Add a person")
                .disabled(!available)
            }
        }
        .sheet(item: $assigning) { event in
            AssignFaceSheet(event: event, people: faces.keys.sorted()) { name in
                await assign(event: event, to: name)
            }
            .environmentObject(appState)
        }
        .alert("New person", isPresented: $showAddPerson) {
            TextField("Name", text: $newPersonName)
            Button("Create") { Task { await createPerson() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create an empty face for someone, then assign their detected faces below.")
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("New name", text: $renameText)
            Button("Save") { Task { await commitRename() } }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .task { await load() }
    }

    // MARK: - Cards

    private var explainer: some View {
        GlassCard {
            HStack(spacing: 12) {
                Image(systemName: "face.smiling.inverse")
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(GlassTheme.cyan)
                    .frame(width: 44, height: 44)
                    .background(GlassTheme.cyan.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("Assign detected faces to people. Frigate learns them, so alerts become \"Alex arrived\" instead of \"person.\"")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(GlassTheme.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    private var unavailableCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(GlassTheme.orange)
                    Text("Face recognition isn't enabled")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(GlassTheme.primary)
                }
                Text("Turn on face recognition in your Frigate config (requires Frigate 0.16+), then come back here to name people.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(GlassTheme.secondary)
            }
        }
    }

    private var peopleCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Known People")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(GlassTheme.primary)

                if loading && faces.isEmpty {
                    ProgressView().tint(GlassTheme.cyan)
                } else if faces.isEmpty {
                    Text("No people yet. Tap ＋ to add one, or assign a detected face below.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(GlassTheme.tertiary)
                } else {
                    ForEach(faces.keys.sorted(), id: \.self) { name in
                        HStack(spacing: 12) {
                            Image(systemName: "person.fill")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(GlassTheme.green)
                                .frame(width: 38, height: 38)
                                .background(GlassTheme.green.opacity(0.15), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(titleize(name))
                                    .font(.system(size: 15, weight: .black))
                                    .foregroundStyle(GlassTheme.primary)
                                Text("\(faces[name]?.count ?? 0) photos")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(GlassTheme.secondary)
                            }
                            Spacer(minLength: 0)
                            Menu {
                                Button { renaming = name; renameText = name } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    Task { await deletePerson(name) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(GlassTheme.secondary)
                            }
                            .accessibilityLabel("Options for \(name)")
                        }
                        .padding(10)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
    }

    private var trainCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent Faces")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(GlassTheme.primary)
                Text("Tap Assign to teach Frigate who this is.")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GlassTheme.tertiary)

                if loading && recentPeople.isEmpty {
                    ProgressView().tint(GlassTheme.cyan)
                } else if recentPeople.isEmpty {
                    Text("No recent person detections.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(GlassTheme.tertiary)
                } else {
                    ForEach(recentPeople) { event in
                        HStack(spacing: 12) {
                            RemoteImage(url: appState.client?.eventThumbnailURL(id: event.id))
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.recognizedFace.map(titleize) ?? "Unknown")
                                    .font(.system(size: 14, weight: .black))
                                    .foregroundStyle(event.recognizedFace == nil ? GlassTheme.orange : GlassTheme.green)
                                Text("\(titleize(event.camera)) · ")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(GlassTheme.tertiary)
                                + Text(Date(timeIntervalSince1970: event.startTime ?? 0), style: .relative)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(GlassTheme.tertiary)
                            }
                            Spacer(minLength: 0)
                            Button { assigning = event } label: {
                                Text("Assign").font(.system(size: 12, weight: .heavy))
                            }
                            .buttonStyle(PillButtonStyle(tint: GlassTheme.blue))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Logic

    private func load() async {
        loading = true
        defer { loading = false }
        guard let client = appState.client else { return }
        do {
            faces = try await client.faces()
            available = true
        } catch {
            available = false
            return
        }
        recentPeople = ((try? await client.events(label: "person", limit: 40, hasSnapshot: true)) ?? [])
            .sorted { ($0.startTime ?? 0) > ($1.startTime ?? 0) }
    }

    private func createPerson() async {
        let name = newPersonName.trimmingCharacters(in: .whitespaces)
        newPersonName = ""
        guard !name.isEmpty, let client = appState.client else { return }
        try? await client.createFace(name: name)
        await load()
    }

    private func assign(event: FrigateEvent, to name: String) async {
        guard let client = appState.client else { return }
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        do {
            try await client.trainFace(name: clean, eventId: event.id)
            showToast("Assigned to \(titleize(clean))")
        } catch {
            // Surface Frigate's real reason (no face in this event / admin needed).
            showToast(error.localizedDescription, isError: true)
        }
        await load()
    }

    private func deletePerson(_ name: String) async {
        guard let client = appState.client, let ids = faces[name], !ids.isEmpty else {
            // No images to remove; just refresh.
            await load(); return
        }
        try? await client.deleteFaceImages(name: name, ids: ids)
        await load()
    }

    private func commitRename() async {
        guard let old = renaming else { return }
        let new = renameText.trimmingCharacters(in: .whitespaces)
        renaming = nil
        guard !new.isEmpty, new != old, let client = appState.client else { return }
        try? await client.renameFace(from: old, to: new)
        await load()
    }

    private func showToast(_ text: String, isError: Bool = false) {
        toast = text
        toastIsError = isError
        Task {
            try? await Task.sleep(nanoseconds: isError ? 4_000_000_000 : 2_000_000_000)
            if toast == text { toast = nil }
        }
    }
}

// MARK: - Assign sheet

private struct AssignFaceSheet: View {
    let event: FrigateEvent
    let people: [String]
    let onAssign: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @State private var newName = ""

    private var cardBG: Color { Color(white: 0.12) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    RemoteImage(url: appState.client?.eventSnapshotURL(id: event.id))
                        .frame(height: 190)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    // New person
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ADD AS NEW PERSON")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(.secondary)
                        TextField("Name (e.g. Alex)", text: $newName)
                            .textInputAutocapitalization(.words)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(14)
                            .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        Button {
                            let name = newName
                            Task { await onAssign(name); dismiss() }
                        } label: {
                            Text("Add Person")
                                .font(.system(size: 16, weight: .heavy))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(newName.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray.opacity(0.4) : GlassTheme.cyan,
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .foregroundStyle(.white)
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(16)
                    .background(cardBG, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    // Existing people
                    VStack(alignment: .leading, spacing: 10) {
                        Text("OR PICK SOMEONE")
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(.secondary)
                        if people.isEmpty {
                            Text("No saved people yet — add one above.")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(people, id: \.self) { name in
                                Button {
                                    Task { await onAssign(name); dismiss() }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "person.crop.circle.fill")
                                            .font(.system(size: 22))
                                            .foregroundStyle(GlassTheme.green)
                                        Text(titleize(name))
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundStyle(.white)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 13, weight: .black))
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(14)
                                    .background(Color(white: 0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(16)
                    .background(cardBG, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .padding(16)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Who is this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Toast

private struct ToastBanner: View {
    let text: String
    var isError: Bool = false
    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background((isError ? GlassTheme.red : GlassTheme.green).opacity(0.95), in: Capsule())
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
