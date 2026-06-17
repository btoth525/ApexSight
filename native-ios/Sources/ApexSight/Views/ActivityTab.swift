import SwiftUI

/// The "everything that's happening" feed: a live activity stream grouped by day,
/// with quick last-24h chips (person / car / Amazon / UPS / FedEx …) that double as
/// filters and counts. Distinct from Review, which is the alert triage queue.
struct ActivityTab: View {
    @EnvironmentObject private var appState: AppState
    // Persisted so the chosen filters survive navigating away and back (and relaunches).
    @AppStorage("activity.selectedCamera") private var selectedCamera = "all"
    @AppStorage("activity.selectedLabel") private var selectedLabel = "all"
    @AppStorage("activity.selectedSubLabel") private var selectedSubLabel = "all"
    @AppStorage("activity.sortNewest") private var sortNewest = true
    @State private var path = NavigationPath()
    // When a filter is active we query the server (the live `appState.events` cache is
    // only the latest ~50, so an older combo would falsely look empty).
    @State private var serverResults: [FrigateEvent] = []
    @State private var loadingFiltered = false
    // A 24h window powering the summary chips, independent of the active filter.
    @State private var last24h: [FrigateEvent] = []

    private static let carriers: Set<String> = [
        "amazon", "ups", "usps", "fedex", "dhl", "an_post", "purolator",
        "dpd", "gls", "postnl", "postnord", "canada_post", "royal_mail"
    ]

    private var isFilterActive: Bool {
        selectedCamera != "all" || selectedLabel != "all" || selectedSubLabel != "all"
    }

    private var displayedEvents: [FrigateEvent] {
        isFilterActive ? serverResults : appState.events
    }

    // MARK: - Grouping into day sections

    struct DaySection: Identifiable { let id: Date; let title: String; let events: [FrigateEvent] }

    private var sections: [DaySection] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: displayedEvents) { event in
            cal.startOfDay(for: Date(timeIntervalSince1970: event.startTime ?? 0))
        }
        return grouped.keys.sorted(by: sortNewest ? (>) : (<)).map { day in
            let evs = grouped[day]!.sorted {
                sortNewest ? ($0.startTime ?? 0) > ($1.startTime ?? 0)
                           : ($0.startTime ?? 0) < ($1.startTime ?? 0)
            }
            return DaySection(id: day, title: dayTitle(day), events: evs)
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .complete, time: .omitted)
    }

    // MARK: - Last-24h summary chips

    struct Tally: Identifiable { let id: String; let emoji: String; let title: String; let count: Int; let isSub: Bool; let key: String }

    private var tallies: [Tally] {
        var labelCounts: [String: Int] = [:]
        var subCounts: [String: Int] = [:]
        for event in last24h {
            labelCounts[event.label.lowercased(), default: 0] += 1
            if let sub = event.subLabel?.lowercased(), Self.carriers.contains(sub) {
                subCounts[sub, default: 0] += 1
            }
        }
        var out = labelCounts.sorted { $0.value > $1.value }.map {
            Tally(id: "l:\($0.key)", emoji: NotificationCopy.emoji(for: $0.key),
                  title: titleize($0.key), count: $0.value, isSub: false, key: $0.key)
        }
        out += subCounts.sorted { $0.value > $1.value }.map {
            Tally(id: "s:\($0.key)", emoji: NotificationCopy.emoji(for: "package", subLabel: $0.key),
                  title: titleize($0.key), count: $0.value, isSub: true, key: $0.key)
        }
        return out
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                GlassBackground()
                ScrollView {
                    // Plain LazyVStack (no pinned headers): pinned section headers in a
                    // LazyVStack recompute offsets as async thumbnails load, which made the
                    // tiles drift/glitch while scrolling or sitting still.
                    LazyVStack(alignment: .leading, spacing: 12) {
                        header

                        if displayedEvents.isEmpty {
                            emptyOrLoading
                        } else {
                            ForEach(sections) { section in
                                sectionHeader(section.title, count: section.events.count)
                                ForEach(section.events) { event in
                                    Button { path.append(event) } label: { EventRow(event: event) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
                .refreshable {
                    await appState.refresh()
                    await loadSummary()
                    await loadFiltered()
                }
                .task {
                    if appState.events.isEmpty { await appState.refresh() }
                    await loadSummary()
                }
                .task(id: "\(selectedCamera)|\(selectedLabel)|\(selectedSubLabel)") { await loadFiltered() }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .glassNavBar()
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        if appState.isLoading || loadingFiltered { ProgressView().tint(GlassTheme.cyan) }
                        Button { sortNewest.toggle() } label: {
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

    // MARK: - Header (cameras + last-24h chips)

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if isFilterActive {
                        chip("✕ Clear", selected: false) {
                            selectedCamera = "all"; selectedLabel = "all"; selectedSubLabel = "all"
                        }
                    }
                    chip("All Cameras", selected: selectedCamera == "all") { selectedCamera = "all" }
                    ForEach(appState.cameras) { cam in
                        chip(titleize(cam.name), selected: selectedCamera == cam.name) {
                            selectedCamera = cam.name
                        }
                    }
                }
                .padding(.horizontal, 2)
            }

            if !tallies.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("LAST 24 HOURS")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(GlassTheme.tertiary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(tallies) { tally in tallyChip(tally) }
                        }
                        .padding(.horizontal, 2)
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private func tallyChip(_ tally: Tally) -> some View {
        let selected = tally.isSub ? selectedSubLabel == tally.key : selectedLabel == tally.key
        return Button {
            if tally.isSub {
                selectedSubLabel = selected ? "all" : tally.key
                selectedLabel = "all"
            } else {
                selectedLabel = selected ? "all" : tally.key
                selectedSubLabel = "all"
            }
        } label: {
            HStack(spacing: 5) {
                Text("\(tally.emoji) \(tally.title)")
                    .font(.system(size: 12, weight: .black))
                Text("\(tally.count)")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(selected ? Color.black : GlassTheme.cyan)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background((selected ? Color.black.opacity(0.18) : GlassTheme.cyan.opacity(0.18)), in: Capsule())
            }
            .foregroundStyle(selected ? Color.black : GlassTheme.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? GlassTheme.cyan : .white.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(GlassTheme.primary)
            Spacer()
            Text("\(count)")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(GlassTheme.secondary)
        }
        .padding(.top, 8)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var emptyOrLoading: some View {
        if (appState.isLoading && appState.events.isEmpty) || loadingFiltered {
            SkeletonList(rows: 6).padding(.top, 4)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 36, weight: .black))
                    .foregroundStyle(GlassTheme.secondary.opacity(0.5))
                Text(isFilterActive ? "No events match these filters." : "No activity yet.")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(GlassTheme.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 50)
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

    // MARK: - Data

    private func loadSummary() async {
        guard let client = appState.client else { return }
        let since = Date().addingTimeInterval(-86_400)
        if let fetched = try? await client.events(after: since, limit: 500) {
            last24h = fetched
        }
    }

    private func loadFiltered() async {
        guard isFilterActive, let client = appState.client else { return }
        loadingFiltered = true
        defer { loadingFiltered = false }
        serverResults = (try? await client.events(
            camera: selectedCamera == "all" ? nil : selectedCamera,
            label: selectedLabel == "all" ? nil : selectedLabel,
            subLabel: selectedSubLabel == "all" ? nil : selectedSubLabel,
            limit: 300
        )) ?? []
    }
}
