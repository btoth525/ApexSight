import SwiftUI

struct TriggersSettingsView: View {
    @EnvironmentObject private var appState: AppState
    // The single shared store owned by AppState, so edits here actually drive the
    // delivery gate (and stay in sync with the per-event "Create Trigger" flow).
    @ObservedObject var store: NotificationTriggerStore
    @State private var isAdding = false
    @State private var editingTrigger: NotificationTrigger?

    var body: some View {
        ZStack {
            GlassBackground()
            if store.triggers.isEmpty {
                VStack(spacing: GlassTheme.Space.l) {
                    EmptyStateView(
                        icon: "bell.badge.slash",
                        title: "No Triggers",
                        message: "Create triggers to get notified for specific cameras, objects, and zones — even when global settings are off."
                    )
                    Button {
                        Haptics.tap()
                        isAdding = true
                    } label: {
                        Label("Add First Trigger", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
                }
                .padding(.horizontal, GlassTheme.Space.l)
            } else {
                List {
                    ForEach(store.triggers) { trigger in
                        triggerRow(trigger)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: GlassTheme.Space.xs, leading: GlassTheme.Space.l, bottom: GlassTheme.Space.xs, trailing: GlassTheme.Space.l))
                    }
                    .onDelete { Haptics.warning(); store.delete(at: $0) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: store.triggers.isEmpty)
        .navigationTitle("Triggers")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Haptics.tap()
                    isAdding = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(GlassTheme.accent)
                }
                .accessibilityLabel("Add trigger")
            }
        }
        .sheet(isPresented: $isAdding) {
            TriggerEditorView(store: store)
                .environmentObject(appState)
        }
        .sheet(item: $editingTrigger) { trigger in
            TriggerEditorView(store: store, existing: trigger)
                .environmentObject(appState)
        }
    }

    private func triggerRow(_ trigger: NotificationTrigger) -> some View {
        GlassCard {
            HStack(spacing: GlassTheme.Space.m) {
                VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
                    Text(trigger.name)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundStyle(trigger.enabled ? GlassTheme.primary : GlassTheme.secondary)

                    HStack(spacing: GlassTheme.Space.xs + 2) {
                        if trigger.cameras.isEmpty {
                            chip("All Cameras", tint: GlassTheme.accent)
                        } else {
                            ForEach(trigger.cameras.prefix(2), id: \.self) { chip(titleize($0), tint: GlassTheme.accent) }
                            if trigger.cameras.count > 2 { chip("+\(trigger.cameras.count - 2)", tint: GlassTheme.accent) }
                        }
                        if trigger.labels.isEmpty {
                            chip("Any Object", tint: GlassTheme.orange)
                        } else {
                            ForEach(trigger.labels.prefix(2), id: \.self) { chip(titleize($0), tint: GlassTheme.orange) }
                        }
                    }

                    if !trigger.requiredZones.isEmpty {
                        HStack(spacing: GlassTheme.Space.xs + 2) {
                            ForEach(trigger.requiredZones.prefix(3), id: \.self) { chip(titleize($0), tint: GlassTheme.green) }
                        }
                    }

                    if trigger.minConfidence > 0 {
                        Text("Min \(Int(trigger.minConfidence * 100))% confidence")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(GlassTheme.tertiary)
                    }
                }
                // Only the info area opens the editor, so it can't fight the Toggle's tap.
                .contentShape(Rectangle())
                .onTapGesture { Haptics.tap(); editingTrigger = trigger }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { trigger.enabled },
                    set: { _ in Haptics.select(); store.toggleEnabled(trigger) }
                ))
                .labelsHidden()
                .tint(GlassTheme.accent)
                .accessibilityLabel("\(trigger.name) enabled")
            }
        }
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(tint)
            .padding(.horizontal, GlassTheme.Space.s)
            .padding(.vertical, GlassTheme.Space.xs)
            .background(tint.opacity(0.14), in: Capsule())
    }
}
