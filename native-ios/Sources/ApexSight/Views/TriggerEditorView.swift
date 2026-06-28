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
                    VStack(spacing: GlassTheme.Space.l) {
                        GlassCard {
                            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                                SectionHeader("Name")
                                TextField("e.g. Person at Front Door", text: $name)
                                    .font(.body)
                                    .foregroundStyle(GlassTheme.primary)
                                    .tint(GlassTheme.accent)
                            }
                        }

                        multiSelectCard(
                            title: "Cameras",
                            subtitle: "Empty = all cameras",
                            options: appState.cameras.map(\.name),
                            selected: $selectedCameras,
                            tint: GlassTheme.accent
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
                            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                                SectionHeader("Min Confidence") {
                                    Text(minConfidence > 0 ? "\(Int(minConfidence * 100))%" : "Any")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(GlassTheme.accent)
                                }
                                Slider(value: $minConfidence, in: 0...1, step: 0.05)
                                    .tint(GlassTheme.accent)
                                    .sensoryFeedback(.selection, trigger: minConfidence)
                                    .accessibilityLabel("Minimum confidence")
                                    .accessibilityValue(minConfidence > 0 ? "\(Int(minConfidence * 100)) percent" : "Any")
                                Text("Only notify when detection confidence is at least this high.")
                                    .font(.footnote)
                                    .foregroundStyle(GlassTheme.secondary)
                            }
                        }

                        GlassCard {
                            Toggle(isOn: $respectQuietHours) {
                                VStack(alignment: .leading, spacing: GlassTheme.Space.xs - 1) {
                                    Text("Respect Quiet Hours")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(GlassTheme.primary)
                                    Text("Suppress this trigger during your quiet hours window.")
                                        .font(.footnote)
                                        .foregroundStyle(GlassTheme.secondary)
                                }
                            }
                            .tint(GlassTheme.accent)
                            .sensoryFeedback(.selection, trigger: respectQuietHours)
                        }

                        GlassCard {
                            Toggle(isOn: $enabled) {
                                Text("Enabled")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(GlassTheme.primary)
                            }
                            .tint(GlassTheme.accent)
                            .sensoryFeedback(.selection, trigger: enabled)
                        }
                    }
                    .padding(GlassTheme.Space.l)
                }
            }
            .navigationTitle(existing == nil ? "New Trigger" : "Edit Trigger")
            .navigationBarTitleDisplayMode(.inline)
            .glassNavBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { Haptics.tap(); dismiss() }
                        .font(.body)
                        .foregroundStyle(GlassTheme.secondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") { save() }
                        .font(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(isNameValid ? GlassTheme.accent : GlassTheme.tertiary)
                        .disabled(!isNameValid)
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

    private var isNameValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        var trigger = existing ?? NotificationTrigger(name: trimmedName)
        trigger.name = trimmedName
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
        Haptics.success()
        dismiss()
    }

    private func multiSelectCard(title: String, subtitle: String, options: [String], selected: Binding<Set<String>>, tint: Color) -> some View {
        let uniqueOptions = Array(Set(options)).sorted()
        return GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader(title, subtitle: subtitle)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: GlassTheme.Space.s)], spacing: GlassTheme.Space.s) {
                    ForEach(uniqueOptions, id: \.self) { option in
                        let isSelected = selected.wrappedValue.contains(option)
                        Button {
                            Haptics.select()
                            if isSelected { selected.wrappedValue.remove(option) }
                            else { selected.wrappedValue.insert(option) }
                        } label: {
                            Text(titleize(option))
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(isSelected ? .black : tint)
                                .padding(.horizontal, GlassTheme.Space.m)
                                .padding(.vertical, GlassTheme.Space.s - 1)
                                .frame(maxWidth: .infinity)
                                .background(isSelected ? tint : tint.opacity(0.12), in: Capsule())
                                .overlay {
                                    if !isSelected {
                                        Capsule().strokeBorder(GlassTheme.separator, lineWidth: 1)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .animation(.easeInOut(duration: 0.15), value: isSelected)
                        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    }
                }
            }
        }
    }
}
