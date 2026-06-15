import SwiftUI

struct TriggerEditorView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let store: NotificationTriggerStore
    let existing: NotificationTrigger?

    @State private var name: String
    @State private var selectedCameras: Set<String>
    @State private var selectedLabels: Set<String>
    @State private var selectedZones: Set<String>
    @State private var minConfidence: Double
    @State private var respectQuietHours: Bool
    @State private var enabled: Bool
    @State private var availableLabels: [String] = []
    @State private var availableZones: [String] = []

    init(store: NotificationTriggerStore, existing: NotificationTrigger? = nil) {
        self.store = store
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _selectedCameras = State(initialValue: Set(existing?.cameras ?? []))
        _selectedLabels = State(initialValue: Set(existing?.labels ?? []))
        _selectedZones = State(initialValue: Set(existing?.requiredZones ?? []))
        _minConfidence = State(initialValue: existing?.minConfidence ?? 0.0)
        _respectQuietHours = State(initialValue: existing?.respectQuietHours ?? true)
        _enabled = State(initialValue: existing?.enabled ?? true)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()
                ScrollView {
                    VStack(spacing: 14) {
                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Name")
                                    .font(.system(size: 13, weight: .black))
                                    .foregroundStyle(GlassTheme.secondary)
                                TextField("e.g. Person at Front Door", text: $name)
                                    .font(.system(size: 16, weight: .heavy))
                                    .foregroundStyle(GlassTheme.primary)
                            }
                        }

                        multiSelectCard(
                            title: "Cameras",
                            subtitle: "Empty = all cameras",
                            options: appState.cameras.map(\.name),
                            selected: $selectedCameras,
                            tint: GlassTheme.cyan
                        )

                        multiSelectCard(
                            title: "Objects",
                            subtitle: "Empty = any object",
                            options: availableLabels.isEmpty ? ["person", "car", "package", "animal", "vehicle"] : availableLabels,
                            selected: $selectedLabels,
                            tint: GlassTheme.orange
                        )

                        multiSelectCard(
                            title: "Required Zones",
                            subtitle: "All must match — empty = any zone",
                            options: availableZones.isEmpty ? appState.cameras.flatMap(\.zones) : availableZones,
                            selected: $selectedZones,
                            tint: GlassTheme.green
                        )

                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("Min Confidence")
                                        .font(.system(size: 15, weight: .black))
                                        .foregroundStyle(GlassTheme.primary)
                                    Spacer()
                                    Text(minConfidence > 0 ? "\(Int(minConfidence * 100))%" : "Any")
                                        .font(.system(size: 14, weight: .black))
                                        .foregroundStyle(GlassTheme.cyan)
                                }
                                Slider(value: $minConfidence, in: 0...1, step: 0.05)
                                    .tint(GlassTheme.cyan)
                                Text("Only notify when detection confidence is at least this high.")
                                    .font(.system(size: 11, weight: .heavy))
                                    .foregroundStyle(GlassTheme.secondary)
                            }
                        }

                        GlassCard {
                            Toggle(isOn: $respectQuietHours) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Respect Quiet Hours")
                                        .font(.system(size: 15, weight: .black))
                                        .foregroundStyle(GlassTheme.primary)
                                    Text("Suppress this trigger during your quiet hours window.")
                                        .font(.system(size: 11, weight: .heavy))
                                        .foregroundStyle(GlassTheme.secondary)
                                }
                            }
                            .tint(GlassTheme.cyan)
                        }

                        GlassCard {
                            Toggle(isOn: $enabled) {
                                Text("Enabled")
                                    .font(.system(size: 15, weight: .black))
                                    .foregroundStyle(GlassTheme.primary)
                            }
                            .tint(GlassTheme.cyan)
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle(existing == nil ? "New Trigger" : "Edit Trigger")
            .navigationBarTitleDisplayMode(.inline)
            .glassNavBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(GlassTheme.secondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(name.isEmpty ? GlassTheme.tertiary : GlassTheme.cyan)
                        .disabled(name.isEmpty)
                }
            }
            .task {
                if let client = appState.client {
                    availableLabels = (try? await client.labels()) ?? []
                    let zones = appState.cameras.flatMap { $0.zones }
                    availableZones = Array(Set(zones)).sorted()
                }
            }
        }
    }

    private func save() {
        var trigger = existing ?? NotificationTrigger(name: name)
        trigger.name = name
        trigger.cameras = Array(selectedCameras)
        trigger.labels = Array(selectedLabels)
        trigger.requiredZones = Array(selectedZones)
        trigger.minConfidence = minConfidence
        trigger.respectQuietHours = respectQuietHours
        trigger.enabled = enabled

        if existing != nil {
            store.update(trigger)
        } else {
            store.add(trigger)
        }
        dismiss()
    }

    private func multiSelectCard(title: String, subtitle: String, options: [String], selected: Binding<Set<String>>, tint: Color) -> some View {
        let uniqueOptions = Array(Set(options)).sorted()
        return GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .black))
                        .foregroundStyle(GlassTheme.primary)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(GlassTheme.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
                    ForEach(uniqueOptions, id: \.self) { option in
                        let isSelected = selected.wrappedValue.contains(option)
                        Button {
                            if isSelected { selected.wrappedValue.remove(option) }
                            else { selected.wrappedValue.insert(option) }
                        } label: {
                            Text(titleize(option))
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(isSelected ? .black : tint)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity)
                                .background(isSelected ? tint : tint.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
