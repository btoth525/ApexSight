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
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var sharePayload: SharePayload?

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
        // Drop timestamp-less events so they don't bucket into a phantom "Jan 1, 1970" day.
        let grouped = Dictionary(grouping: displayedEvents.filter { $0.startTime != nil }) { event in
            cal.startOfDay(for: Date(timeIntervalSince1970: event.startTime ?? 0))
        }
        return grouped.keys.sorted(by: sortNewest ? (>) : (<)).compactMap { day in
            guard let evs = grouped[day] else { return nil }
            let sorted = evs.sorted {
                sortNewest ? ($0.startTime ?? 0) > ($1.startTime ?? 0)
                           : ($0.startTime ?? 0) < ($1.startTime ?? 0)
            }
            return DaySection(id: day, title: dayTitle(day), events: sorted)
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
                    LazyVStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                        header

                        if displayedEvents.isEmpty {
                            emptyOrLoading
                        } else {
                            ForEach(sections) { section in
                                sectionHeader(section.title, count: section.events.count)
                                ForEach(section.events) { event in
                                    Button { path.append(event) } label: { EventRow(event: event) }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button { path.append(event) } label: {
                                                Label("Open", systemImage: "arrow.up.forward.app")
                                            }
                                            if event.hasClip == true {
                                                Button { Task { await shareClip(event) } } label: {
                                                    Label("Share Clip", systemImage: "square.and.arrow.up")
                                                }
                                                Button { saveClip(event) } label: {
                                                    Label("Save Clip to Photos", systemImage: "square.and.arrow.down")
                                                }
                                            }
                                        }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, GlassTheme.Space.l)
                    .padding(.bottom, GlassTheme.Space.xl)
                }
                .softScrollEdges()
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
            .overlay(alignment: .bottom) { activityToast }
            .sheet(item: $sharePayload) { payload in
                ShareSheet(items: payload.items)
            }
            .onDisappear { toastTask?.cancel(); toastTask = nil }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: GlassTheme.Space.m) {
                        if appState.isLoading || loadingFiltered { ProgressView().tint(GlassTheme.accent) }
                        Button { Haptics.select(); sortNewest.toggle() } label: {
                            Image(systemName: sortNewest ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(GlassTheme.accent)
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
        VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: GlassTheme.Space.s) {
                    if isFilterActive {
                        chip("Clear", selected: false, systemImage: "xmark") {
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
                VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
                    Text("Last 24 Hours")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(GlassTheme.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: GlassTheme.Space.s) {
                            ForEach(tallies) { tally in tallyChip(tally) }
                        }
                        .padding(.horizontal, 2)
                    }
                }
            }
        }
        .padding(.top, GlassTheme.Space.xs)
    }

    private func tallyChip(_ tally: Tally) -> some View {
        let selected = tally.isSub ? selectedSubLabel == tally.key : selectedLabel == tally.key
        return Button {
            Haptics.select()
            if tally.isSub {
                selectedSubLabel = selected ? "all" : tally.key
                selectedLabel = "all"
            } else {
                selectedLabel = selected ? "all" : tally.key
                selectedSubLabel = "all"
            }
        } label: {
            HStack(spacing: GlassTheme.Space.xs) {
                Text("\(tally.emoji) \(tally.title)")
                    .font(.subheadline.weight(.semibold))
                Text("\(tally.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selected ? .white : GlassTheme.accent)
                    .padding(.horizontal, GlassTheme.Space.xs + 2)
                    .padding(.vertical, 1)
                    .background(
                        (selected ? Color.white.opacity(0.22) : GlassTheme.accent.opacity(0.18)),
                        in: Capsule()
                    )
            }
            .foregroundStyle(selected ? .white : GlassTheme.primary)
            .padding(.horizontal, GlassTheme.Space.m)
            .padding(.vertical, GlassTheme.Space.s)
            .background {
                Capsule().fill(selected ? GlassTheme.accent : GlassTheme.surface)
            }
            .overlay {
                if !selected { Capsule().strokeBorder(GlassTheme.separator, lineWidth: 1) }
            }
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(GlassTheme.primary)
            Spacer()
            Text("\(count)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(GlassTheme.secondary)
                .monospacedDigit()
        }
        .padding(.top, GlassTheme.Space.s)
        .padding(.horizontal, GlassTheme.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var emptyOrLoading: some View {
        if (appState.isLoading && appState.events.isEmpty) || loadingFiltered {
            SkeletonList(rows: 6).padding(.top, GlassTheme.Space.xs)
        } else if showErrorState {
            errorState
        } else if isFilterActive {
            EmptyStateView(
                icon: "line.3.horizontal.decrease.circle",
                title: "No Matches",
                message: "No events match these filters. Try clearing them to see all activity."
            )
            .padding(.top, GlassTheme.Space.xxl)
        } else {
            EmptyStateView(
                icon: "sparkles",
                title: "No Activity Yet",
                message: "Events from your cameras will appear here as they happen."
            )
            .padding(.top, GlassTheme.Space.xxl)
        }
    }

    /// The last fetch failed (server unreachable) AND we have nothing to show — so we offer
    /// Retry instead of a misleading "No Activity Yet" over a dead connection.
    private var showErrorState: Bool {
        !appState.isReachable && displayedEvents.isEmpty
    }

    private func retry() async {
        Haptics.tap()
        await appState.refresh()
        await loadSummary()
        await loadFiltered()
    }

    /// Calm error state with a retry, so a failed load is recoverable instead of a blank feed.
    private var errorState: some View {
        VStack(spacing: GlassTheme.Space.l) {
            EmptyStateView(
                icon: "wifi.exclamationmark",
                title: "Can't Reach Server",
                message: "We couldn't load activity. Check your connection and try again."
            )
            Button {
                Task { await retry() }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
        }
        .padding(.top, GlassTheme.Space.xxl)
    }

    private func chip(_ title: String, selected: Bool, systemImage: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: { Haptics.select(); action() }) {
            HStack(spacing: GlassTheme.Space.xs) {
                if let systemImage {
                    Image(systemName: systemImage).font(.caption2.weight(.semibold))
                }
                Text(title).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(selected ? .white : GlassTheme.primary)
            .padding(.horizontal, GlassTheme.Space.m)
            .padding(.vertical, GlassTheme.Space.s)
            .background {
                Capsule().fill(selected ? GlassTheme.accent : GlassTheme.surface)
            }
            .overlay {
                if !selected { Capsule().strokeBorder(GlassTheme.separator, lineWidth: 1) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
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

    // MARK: - Quick save (long-press → Save Clip)

    private func saveClip(_ event: FrigateEvent) {
        guard let client = appState.client else { return }
        Haptics.tap()
        showToast("Saving clip…")
        Task { @MainActor in
            do {
                try await ClipDownloader.downloadToPhotos(
                    url: client.eventClipURL(id: event.id),
                    client: client,
                    fileName: "Apex-\(event.camera)-\(event.id)"
                )
                Haptics.success()
                showToast("Saved to Photos ✓")
            } catch {
                showToast(error.localizedDescription)
            }
        }
    }

    private func shareClip(_ event: FrigateEvent) async {
        guard let client = appState.client else { return }
        Haptics.tap()
        showToast("Preparing clip…")
        do {
            let url = try await ClipDownloader.downloadToTempFile(
                url: client.eventClipURL(id: event.id),
                client: client,
                fileName: "Apex-\(event.camera)-\(event.id)"
            )
            sharePayload = SharePayload(url: url)
        } catch {
            showToast(error.localizedDescription)
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { toast = message }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { if toast == message { toast = nil } }
        }
    }

    @ViewBuilder
    private var activityToast: some View {
        if let toast {
            Text(toast)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, GlassTheme.Space.l)
                .padding(.vertical, GlassTheme.Space.m)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(GlassTheme.separator, lineWidth: 1) }
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                .padding(.bottom, GlassTheme.Space.l)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
