import SwiftUI

struct ActivityTab: View {
    @EnvironmentObject private var appState: AppState
    // Persisted so the chosen filters survive navigating away and back (and relaunches).
    @AppStorage("activity.selectedCamera") private var selectedCamera = "all"
    @AppStorage("activity.selectedLabel") private var selectedLabel = "all"
    @AppStorage("activity.sortNewest") private var sortNewest = true
    @State private var path = NavigationPath()
    // When a filter is active we query the server (the live `appState.events` cache is
    // only the latest ~50, so an older camera/label combo would falsely look empty).
    @State private var serverResults: [FrigateEvent] = []
    @State private var loadingFiltered = false

    private var labels: [String] {
        Array(Set(appState.labels + appState.events.map(\.label))).sorted()
    }

    private var isFilterActive: Bool { selectedCamera != "all" || selectedLabel != "all" }

    private var filtered: [FrigateEvent] {
        let base = isFilterActive ? serverResults : appState.events
        return sortNewest
            ? base.sorted { ($0.startTime ?? 0) > ($1.startTime ?? 0) }
            : base.sorted { ($0.startTime ?? 0) < ($1.startTime ?? 0) }
    }

    private func loadFiltered() async {
        guard isFilterActive, let client = appState.client else { return }
        loadingFiltered = true
        defer { loadingFiltered = false }
        serverResults = (try? await client.events(
            camera: selectedCamera == "all" ? nil : selectedCamera,
            label: selectedLabel == "all" ? nil : selectedLabel,
            limit: 300
        )) ?? []
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                GlassBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // Camera filter
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                if isFilterActive {
                                    chip("✕ Clear", selected: false) {
                                        selectedCamera = "all"; selectedLabel = "all"
                                    }
                                }
                                chip("All Cameras", selected: selectedCamera == "all") { selectedCamera = "all" }
                                ForEach(appState.cameras) { cam in
                                    chip(titleize(cam.name), selected: selectedCamera == cam.name) {
                                        selectedCamera = cam.name
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                        .padding(.top, 8)

                        // Label filter
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                chip("All Objects", selected: selectedLabel == "all") { selectedLabel = "all" }
                                ForEach(labels, id: \.self) { label in
                                    chip("\(NotificationCopy.emoji(for: label)) \(titleize(label))", selected: selectedLabel == label) {
                                        selectedLabel = label
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }

                        Text("\(filtered.count) matching alerts")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundStyle(GlassTheme.secondary)
                            .padding(.horizontal, 16)

                        if filtered.isEmpty {
                            if (appState.isLoading && appState.events.isEmpty) || loadingFiltered {
                                SkeletonList(rows: 6)
                                    .padding(.top, 4)
                            } else {
                                Text(isFilterActive ? "No events match these filters." : "No events yet.")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(GlassTheme.secondary)
                                    .padding(.horizontal, 16)
                            }
                        } else {
                            LazyVStack(spacing: 10) {
                                ForEach(filtered) { event in
                                    Button { path.append(event) } label: {
                                        EventRow(event: event)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 20)
                        }
                    }
                }
                .refreshable {
                    await appState.refresh()
                    await loadFiltered()
                }
                .task { if appState.events.isEmpty { await appState.refresh() } }
                // Re-query the server whenever the camera/label filter changes.
                .task(id: "\(selectedCamera)|\(selectedLabel)") { await loadFiltered() }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .glassNavBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        if appState.isLoading { ProgressView().tint(GlassTheme.cyan) }
                        Button {
                            sortNewest.toggle()
                        } label: {
                            Image(systemName: sortNewest ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(GlassTheme.cyan)
                        }
                        .accessibilityLabel(sortNewest ? "Sorted newest first" : "Sorted oldest first")
                        .accessibilityHint("Toggles sort order")
                    }
                }
            }
            .navigationDestination(for: FrigateEvent.self) { event in
                EventDetailView(event: event)
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(selected ? Color.black : GlassTheme.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(selected ? GlassTheme.cyan : .white.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
