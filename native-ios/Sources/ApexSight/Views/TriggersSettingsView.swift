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
                VStack(spacing: 14) {
                    Image(systemName: "bell.badge.slash")
                        .font(.system(size: 44, weight: .black))
                        .foregroundStyle(GlassTheme.secondary)
                    Text("No Triggers")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(GlassTheme.primary)
                    Text("Create triggers to get notified for specific cameras, objects, and zones — even when global settings are off.")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(GlassTheme.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button {
                        isAdding = true
                    } label: {
                        Label("Add First Trigger", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(PillButtonStyle(tint: GlassTheme.cyan))
                    .padding(.top, 4)
                }
            } else {
                List {
                    ForEach(store.triggers) { trigger in
                        triggerRow(trigger)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .onTapGesture { editingTrigger = trigger }
                    }
                    .onDelete { store.delete(at: $0) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Triggers")
        .navigationBarTitleDisplayMode(.inline)
        .glassNavBar()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isAdding = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(GlassTheme.cyan)
                }
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
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(trigger.name)
                        .font(.system(size: 16, weight: .black))
                        .foregroundStyle(trigger.enabled ? GlassTheme.primary : GlassTheme.secondary)

                    HStack(spacing: 6) {
                        if trigger.cameras.isEmpty {
                            chip("All Cameras", tint: GlassTheme.cyan)
                        } else {
                            ForEach(trigger.cameras.prefix(2), id: \.self) { chip(titleize($0), tint: GlassTheme.cyan) }
                            if trigger.cameras.count > 2 { chip("+\(trigger.cameras.count - 2)", tint: GlassTheme.cyan) }
                        }
                        if trigger.labels.isEmpty {
                            chip("Any Object", tint: GlassTheme.orange)
                        } else {
                            ForEach(trigger.labels.prefix(2), id: \.self) { chip(titleize($0), tint: GlassTheme.orange) }
                        }
                    }

                    if !trigger.requiredZones.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(trigger.requiredZones.prefix(3), id: \.self) { chip(titleize($0), tint: GlassTheme.green) }
                        }
                    }

                    if trigger.minConfidence > 0 {
                        Text("Min \(Int(trigger.minConfidence * 100))% confidence")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(GlassTheme.tertiary)
                    }
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { trigger.enabled },
                    set: { _ in store.toggleEnabled(trigger) }
                ))
                .labelsHidden()
                .tint(GlassTheme.cyan)
            }
        }
    }

    private func chip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
    }
}
