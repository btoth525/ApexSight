import SwiftUI

struct CameraGroupsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: CameraGroupStore
    @State private var showEditor = false
    @State private var editingGroup: CameraGroup?
    @State private var pendingDeletion: CameraGroup?

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                    if store.groups.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.groups) { group in
                            groupRow(group)
                        }
                    }

                    Button {
                        Haptics.tap()
                        showEditor = true
                    } label: {
                        Label("New Group", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
                    .padding(.top, GlassTheme.Space.xs)
                }
                .padding(GlassTheme.Space.l)
            }
        }
        .navigationTitle("Camera Groups")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .sheet(isPresented: $showEditor) {
            CameraGroupEditor(store: store)
                .environmentObject(appState)
                .preferredColorScheme(.dark)
        }
        .sheet(item: $editingGroup) { group in
            CameraGroupEditor(store: store, editing: group)
                .environmentObject(appState)
                .preferredColorScheme(.dark)
        }
        // Deleting a group is destructive — confirm before dropping it.
        .confirmationDialog(
            "Delete this group?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { group in
            Button("Delete \(group.name)", role: .destructive) {
                if let index = store.groups.firstIndex(where: { $0.id == group.id }) {
                    store.delete(at: IndexSet(integer: index))
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func groupRow(_ group: CameraGroup) -> some View {
        GlassCard {
            HStack(spacing: GlassTheme.Space.m) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(GlassTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(GlassTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
                    .cardStroke(GlassTheme.Radius.tile)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(GlassTheme.primary)
                    Text("\(group.cameraNames.count) cameras · \(group.columns)-up")
                        .font(.subheadline)
                        .foregroundStyle(GlassTheme.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    Haptics.warning()
                    pendingDeletion = group
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(GlassTheme.red)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete \(group.name)")
            }
        }
        // Tap anywhere on the card (except the trash button) to edit the group.
        .contentShape(Rectangle())
        .onTapGesture { Haptics.tap(); editingGroup = group }
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: "square.grid.2x2",
            title: "No groups yet",
            message: "Create a group to watch a custom set of cameras together in one wall."
        )
        .padding(.top, GlassTheme.Space.xxl)
    }
}

struct CameraGroupEditor: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: CameraGroupStore
    @Environment(\.dismiss) private var dismiss

    private let editing: CameraGroup?
    @State private var name: String
    @State private var selected: Set<String>
    @State private var columns: Int

    init(store: CameraGroupStore, editing: CameraGroup? = nil) {
        self.store = store
        self.editing = editing
        _name = State(initialValue: editing?.name ?? "")
        _selected = State(initialValue: Set(editing?.cameraNames ?? []))
        _columns = State(initialValue: editing?.columns ?? 2)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                        GlassCard {
                            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                                SectionHeader("Name")
                                TextField("Front of House", text: $name)
                                    .font(.body)
                                    .foregroundStyle(GlassTheme.primary)
                                    .padding(GlassTheme.Space.m)
                                    .background(GlassTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
                                    .cardStroke(GlassTheme.Radius.tile)
                            }
                        }

                        GlassCard {
                            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                                SectionHeader("Layout")
                                Picker("Columns", selection: $columns) {
                                    Text("1-up").tag(1)
                                    Text("2×2").tag(2)
                                    Text("3-up").tag(3)
                                }
                                .pickerStyle(.segmented)
                            }
                        }

                        GlassCard {
                            VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
                                SectionHeader("Cameras")
                                    .padding(.bottom, GlassTheme.Space.xs)
                                ForEach(appState.cameras) { camera in
                                    cameraToggle(camera)
                                }
                            }
                        }
                    }
                    .padding(GlassTheme.Space.l)
                }
            }
            .navigationTitle(editing == nil ? "New Group" : "Edit Group")
            .navigationBarTitleDisplayMode(.inline)
            .glassNavBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || selected.isEmpty)
                }
            }
        }
    }

    private func cameraToggle(_ camera: FrigateCamera) -> some View {
        Button {
            Haptics.select()
            if selected.contains(camera.name) { selected.remove(camera.name) }
            else { selected.insert(camera.name) }
        } label: {
            HStack(spacing: GlassTheme.Space.m) {
                Image(systemName: selected.contains(camera.name) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(selected.contains(camera.name) ? GlassTheme.accent : GlassTheme.tertiary)
                Text(titleize(camera.name))
                    .font(.body.weight(.medium))
                    .foregroundStyle(GlassTheme.primary)
                Spacer()
            }
            .padding(.vertical, GlassTheme.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func save() {
        let ordered = appState.cameras.map(\.name).filter { selected.contains($0) }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if var updated = editing {
            updated.name = trimmed
            updated.cameraNames = ordered
            updated.columns = columns
            store.update(updated)
        } else {
            store.add(name: trimmed, cameraNames: ordered, columns: columns)
        }
        dismiss()
    }
}
