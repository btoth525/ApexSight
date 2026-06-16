import SwiftUI

struct CameraGroupsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: CameraGroupStore
    @State private var showEditor = false
    @State private var editingGroup: CameraGroup?

    var body: some View {
        ZStack {
            GlassBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.groups.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.groups) { group in
                            groupRow(group)
                        }
                    }

                    Button {
                        showEditor = true
                    } label: {
                        Label("New Group", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PillButtonStyle(tint: GlassTheme.blue))
                }
                .padding(18)
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
    }

    private func groupRow(_ group: CameraGroup) -> some View {
        GlassCard {
            HStack(spacing: 14) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(GlassTheme.cyan)
                    .frame(width: 44, height: 44)
                    .background(GlassTheme.cyan.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.name)
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(GlassTheme.primary)
                    Text("\(group.cameraNames.count) cameras · \(group.columns)-up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(GlassTheme.secondary)
                }
                Spacer()
                Button(role: .destructive) {
                    if let index = store.groups.firstIndex(where: { $0.id == group.id }) {
                        store.delete(at: IndexSet(integer: index))
                    }
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(GlassTheme.red)
                }
                .buttonStyle(.plain)
            }
        }
        // Tap anywhere on the card (except the trash button) to edit the group.
        .contentShape(Rectangle())
        .onTapGesture { editingGroup = group }
    }

    private var emptyState: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("No groups yet")
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(GlassTheme.primary)
                Text("Create a group to watch a custom set of cameras together in one wall.")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(GlassTheme.secondary)
            }
        }
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
                    VStack(alignment: .leading, spacing: 16) {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Name")
                                    .font(.system(size: 13, weight: .black))
                                    .foregroundStyle(GlassTheme.secondary)
                                TextField("Front of House", text: $name)
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(GlassTheme.primary)
                                    .padding(12)
                                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }

                        GlassCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Layout")
                                    .font(.system(size: 13, weight: .black))
                                    .foregroundStyle(GlassTheme.secondary)
                                Picker("Columns", selection: $columns) {
                                    Text("1-up").tag(1)
                                    Text("2×2").tag(2)
                                    Text("3-up").tag(3)
                                }
                                .pickerStyle(.segmented)
                            }
                        }

                        GlassCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Cameras")
                                    .font(.system(size: 13, weight: .black))
                                    .foregroundStyle(GlassTheme.secondary)
                                ForEach(appState.cameras) { camera in
                                    cameraToggle(camera)
                                }
                            }
                        }
                    }
                    .padding(18)
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
            if selected.contains(camera.name) { selected.remove(camera.name) }
            else { selected.insert(camera.name) }
        } label: {
            HStack {
                Image(systemName: selected.contains(camera.name) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(selected.contains(camera.name) ? GlassTheme.cyan : GlassTheme.tertiary)
                Text(titleize(camera.name))
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(GlassTheme.primary)
                Spacer()
            }
            .padding(.vertical, 4)
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
