import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @State private var selectedCamera = "all"
    @State private var selectedLabel = "all"
    @State private var selectedSubLabel = "all"
    @State private var selectedZone = "all"
    @State private var afterDate: Date? = nil
    @State private var showDateFilter = false
    @State private var showFilters = false
    @State private var results: [FrigateEvent] = []
    /// True when `results` came from a relevance-ranked semantic/keyword search, so we
    /// preserve Frigate's best-match-first order (and show descriptions) instead of
    /// re-sorting by time.
    @State private var resultsRanked = false
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var errorMessage: String?
    @State private var plateQuery = ""
    @State private var sortNewest = true
    @State private var path = NavigationPath()
    @State private var showAlbums = false
    @State private var answer: String?
    @State private var faceNames: [String] = []

    // Browse view (default state): a larger recent set grouped by object.
    @State private var browseEvents: [FrigateEvent] = []
    @State private var loadingBrowse = false
    // Grouped once when data changes (not recomputed every render) for speed.
    @State private var groups: [ObjectGroup] = []

    private var sortedResults: [FrigateEvent] {
        sortNewest
            ? results.sorted { ($0.startTime ?? 0) > ($1.startTime ?? 0) }
            : results.sorted { ($0.startTime ?? 0) < ($1.startTime ?? 0) }
    }

    /// Ranked searches keep Frigate's relevance order (best match first); everything
    /// else uses the time sort the user picked.
    private var displayResults: [FrigateEvent] {
        resultsRanked ? results : sortedResults
    }

    private var allLabels: [String] {
        Array(Set(appState.labels + appState.events.map(\.label))).sorted()
    }

    private var allSubLabels: [String] { Array(Set(appState.subLabels)).sorted() }
    private var allZones: [String] { Array(Set(appState.cameras.flatMap(\.zones))).sorted() }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                GlassBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                        searchBar
                        if showFilters { filterSection }
                        if showDateFilter { dateFilterCard }

                        if isSearching {
                            // A results-shaped skeleton, not a lone spinner — the screen
                            // keeps its rhythm while the multi-matcher search runs.
                            resultsSkeleton
                                .transition(.opacity)
                        } else if hasSearched {
                            resultsSection
                                .transition(.opacity)
                        } else {
                            browseSection
                                .transition(.opacity)
                        }
                    }
                    .padding(GlassTheme.Space.l)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isSearching)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: hasSearched)
                }
                .refreshable { await loadBrowse() }
            }
            .navigationTitle("Explore")
            .navigationBarTitleDisplayMode(.large)
            .glassNavBar()
            .navigationDestination(for: FrigateEvent.self) { event in
                EventDetailView(event: event)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Haptics.tap(); showAlbums = true } label: {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(GlassTheme.accent)
                    }
                    .accessibilityLabel("Smart albums")
                }
            }
            .sheet(isPresented: $showAlbums) {
                SmartAlbumsView().environmentObject(appState)
            }
            .task {
                if browseEvents.isEmpty { await loadBrowse() } else if groups.isEmpty { rebuildGroups() }
                if faceNames.isEmpty, let client = appState.client, let faces = try? await client.faces() {
                    faceNames = Array(faces.keys)
                }
            }
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: GlassTheme.Space.s) {
            HStack(spacing: GlassTheme.Space.s) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(GlassTheme.secondary)

                TextField("Ask anything…", text: $query)
                    .font(.system(.body))
                    .foregroundStyle(GlassTheme.primary)
                    .submitLabel(.search)
                    .onSubmit { Haptics.tap(); Task { await performSearch() } }

                if !query.isEmpty || hasSearched {
                    Button {
                        Haptics.tap()
                        query = ""
                        results = []
                        answer = nil
                        hasSearched = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(GlassTheme.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, GlassTheme.Space.m)
            .padding(.vertical, 10)
            .background(GlassTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous))
            .cardStroke(GlassTheme.Radius.chip)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: query.isEmpty)

            Button {
                Haptics.select()
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) { showFilters.toggle() }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle\(showFilters ? ".fill" : "")")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(showFilters ? GlassTheme.accent : GlassTheme.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Filters")
            .accessibilityValue(showFilters ? "Shown" : "Hidden")

            Button {
                Haptics.tap()
                Task { await performSearch() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(isSearching ? GlassTheme.tertiary : GlassTheme.accent)
            }
            .buttonStyle(.plain)
            .disabled(isSearching)
            .accessibilityLabel("Search")
        }
    }

    // MARK: - Browse (grouped by object)

    private struct ObjectGroup: Identifiable {
        let id: String
        let title: String
        let emoji: String
        let label: String?
        let subLabel: String?
        let events: [FrigateEvent]
    }

    private func rebuildGroups() {
        let source = browseEvents.isEmpty ? appState.events : browseEvents

        var byLabel: [String: [FrigateEvent]] = [:]
        for e in source { byLabel[e.label, default: []].append(e) }
        let labelGroups = byLabel.map { label, evs in
            ObjectGroup(
                id: "label-\(label)",
                title: titleize(label),
                emoji: NotificationCopy.emoji(for: label),
                label: label, subLabel: nil,
                events: evs.sorted { ($0.startTime ?? 0) > ($1.startTime ?? 0) }
            )
        }
        .sorted { $0.events.count > $1.events.count }

        // Sub-label groups (recognized faces, plates, carriers like Amazon/FedEx, your truck).
        var bySub: [String: [FrigateEvent]] = [:]
        for e in source { if let s = e.subLabel, !s.isEmpty { bySub[s, default: []].append(e) } }
        let subGroups = bySub.map { sub, evs in
            ObjectGroup(
                id: "sub-\(sub)",
                title: titleize(sub),
                emoji: NotificationCopy.emoji(for: evs.first?.label ?? "", subLabel: sub),
                label: nil, subLabel: sub,
                events: evs.sorted { ($0.startTime ?? 0) > ($1.startTime ?? 0) }
            )
        }
        .sorted { $0.events.count > $1.events.count }

        groups = subGroups + labelGroups
    }

    private var browseSection: some View {
        // Lazy so only the groups you've scrolled to instantiate their thumbnails —
        // rendering every group at once fired dozens of image fetches and dropped some.
        LazyVStack(alignment: .leading, spacing: GlassTheme.Space.xl) {
            if loadingBrowse && browseEvents.isEmpty {
                // A grouped-shelf skeleton (header + a row of tiles) so the browse
                // layout is visible immediately instead of a centered spinner.
                browseSkeleton
            } else if groups.isEmpty {
                emptyState
            } else {
                ForEach(groups) { group in
                    groupRow(group)
                }
            }
        }
    }

    /// Mirrors `browseSection`'s shelves (title bar + a horizontal strip of tiles) so
    /// the screen shows its structure while the deep recent window loads.
    private var browseSkeleton: some View {
        VStack(alignment: .leading, spacing: GlassTheme.Space.xl) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
                    SkeletonBlock(cornerRadius: GlassTheme.Radius.chip)
                        .frame(width: 150, height: 18)
                    HStack(spacing: GlassTheme.Space.s) {
                        ForEach(0..<4, id: \.self) { _ in
                            SkeletonBlock(cornerRadius: GlassTheme.Radius.tile)
                                .frame(width: 104, height: 104)
                        }
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// A results-list skeleton (rich rows) used while a search is running.
    private var resultsSkeleton: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SkeletonBlock(cornerRadius: GlassTheme.Radius.chip)
                    .frame(width: 110, height: 20)
                ForEach(0..<5, id: \.self) { _ in
                    HStack(alignment: .top, spacing: GlassTheme.Space.m) {
                        SkeletonBlock(cornerRadius: GlassTheme.Radius.tile)
                            .frame(width: 92, height: 92)
                        VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
                            SkeletonBlock(cornerRadius: 6).frame(height: 14).frame(maxWidth: .infinity, alignment: .leading)
                            SkeletonBlock(cornerRadius: 6).frame(width: 160, height: 12)
                            SkeletonBlock(cornerRadius: 6).frame(height: 12).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func groupRow(_ group: ObjectGroup) -> some View {
        VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
            Button {
                Haptics.tap()
                selectedLabel = group.label ?? "all"
                selectedSubLabel = group.subLabel ?? "all"
                Task { await performSearch() }
            } label: {
                HStack(spacing: GlassTheme.Space.s) {
                    Text("\(group.emoji) \(group.title)")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(GlassTheme.primary)
                    Text("\(group.events.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(GlassTheme.secondary)
                        .padding(.horizontal, GlassTheme.Space.s)
                        .padding(.vertical, 3)
                        .background(GlassTheme.surfaceHigh, in: Capsule())
                    Spacer()
                    HStack(spacing: 3) {
                        Text("See all")
                            .font(.subheadline.weight(.medium))
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(GlassTheme.accent)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("See all \(group.title), \(group.events.count) events")

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: GlassTheme.Space.s) {
                    ForEach(group.events.prefix(8)) { event in
                        Button { Haptics.tap(); path.append(event) } label: {
                            thumbnail(event)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func thumbnail(_ event: FrigateEvent) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let url = appState.client?.eventThumbnailURL(id: event.id) {
                // 104pt tile — decode to ~3x, not the 1000px default (≈9x the pixels shown).
                RemoteImage(url: url, contentMode: .fill, maxPixelSize: 360)
                    .frame(width: 104, height: 104)
                    .clipped()
            } else {
                Color.black.frame(width: 104, height: 104)
            }
            if let start = event.startTime {
                Text(Date(timeIntervalSince1970: start).formatted(.relative(presentation: .numeric)))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(5)
            }
        }
        .frame(width: 104, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous)
                .strokeBorder(GlassTheme.separator, lineWidth: 1)
        }
    }

    /// A ranked semantic-search hit: thumbnail + label/sub-label, time, the GenAI
    /// description (what matched), and a small badge for the match source.
    private func searchResultRow(_ event: FrigateEvent) -> some View {
        HStack(alignment: .top, spacing: GlassTheme.Space.m) {
            if let url = appState.client?.eventThumbnailURL(id: event.id) {
                // 92pt thumbnail — downsample instead of decoding the full-res frame.
                RemoteImage(url: url, contentMode: .fill, maxPixelSize: 360)
                    .frame(width: 92, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: GlassTheme.Radius.tile, style: .continuous)
                    .fill(GlassTheme.surfaceHigh).frame(width: 92, height: 92)
            }
            VStack(alignment: .leading, spacing: GlassTheme.Space.xs) {
                HStack(spacing: GlassTheme.Space.xs) {
                    Text("\(NotificationCopy.emoji(for: event.label, subLabel: event.subLabel)) \(titleize(event.displayLabel))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GlassTheme.primary)
                        .lineLimit(1)
                    if event.searchSource == "description" {
                        Image(systemName: "text.magnifyingglass")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(GlassTheme.accent)
                            .accessibilityLabel("Matched description")
                    }
                }
                Text("\(titleize(event.camera))\(event.startTime.map { " · " + Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "")")
                    .font(.footnote)
                    .foregroundStyle(GlassTheme.secondary)
                    .lineLimit(1)
                if let desc = event.description {
                    Text(desc)
                        .font(.footnote)
                        .foregroundStyle(GlassTheme.tertiary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(GlassTheme.Space.m)
        .background(GlassTheme.surface, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.card, style: .continuous))
        .cardStroke()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Filters

    private var filterSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.m) {
                SectionHeader("Filters")

                chipRow(title: "Cameras", icon: "video", selected: selectedCamera, options: appState.cameras.map(\.name)) {
                    selectedCamera = $0
                }
                chipRow(title: "Labels", icon: "tag", selected: selectedLabel, options: allLabels) {
                    selectedLabel = $0
                }
                if !allSubLabels.isEmpty {
                    chipRow(title: "Sub-Labels", icon: "tag.fill", selected: selectedSubLabel, options: allSubLabels) {
                        selectedSubLabel = $0
                    }
                }
                if !allZones.isEmpty {
                    chipRow(title: "Zones", icon: "mappin", selected: selectedZone, options: allZones) {
                        selectedZone = $0
                    }
                }

                HStack(spacing: GlassTheme.Space.s) {
                    Image(systemName: "car.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(GlassTheme.secondary)
                    TextField("License plate (optional)", text: $plateQuery)
                        .font(.subheadline)
                        .foregroundStyle(GlassTheme.primary)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .submitLabel(.search)
                        .onSubmit { Task { await performSearch() } }
                }
                .padding(GlassTheme.Space.m)
                .background(GlassTheme.surfaceHigh, in: RoundedRectangle(cornerRadius: GlassTheme.Radius.chip, style: .continuous))
                .cardStroke(GlassTheme.Radius.chip)

                Button {
                    Haptics.select()
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) { showDateFilter.toggle() }
                    if !showDateFilter { afterDate = nil }
                } label: {
                    HStack(spacing: GlassTheme.Space.xs) {
                        Image(systemName: showDateFilter ? "calendar.badge.minus" : "calendar.badge.plus")
                            .font(.footnote.weight(.semibold))
                        Text(afterDate.map { "From: \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Date Filter")
                            .font(.footnote.weight(.medium))
                    }
                    .foregroundStyle(showDateFilter ? Color.white : GlassTheme.secondary)
                    .padding(.horizontal, GlassTheme.Space.m)
                    .padding(.vertical, GlassTheme.Space.s)
                    .background(showDateFilter ? AnyShapeStyle(GlassTheme.accent) : AnyShapeStyle(GlassTheme.surfaceHigh), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func chipRow(title: String, icon: String, selected: String, options: [String], onSelect: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip("All \(title)", icon: icon, selected: selected == "all") { onSelect("all") }
                ForEach(options, id: \.self) { opt in
                    filterChip(titleize(opt), icon: nil, selected: selected == opt) { onSelect(opt) }
                }
            }
        }
    }

    private var dateFilterCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: GlassTheme.Space.s) {
                Text("Events After")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(GlassTheme.secondary)
                DatePicker("", selection: Binding(
                    get: { afterDate ?? Date().addingTimeInterval(-86400 * 7) },
                    set: { afterDate = $0 }
                ), displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
                .colorScheme(.dark)
                .onAppear { if afterDate == nil { afterDate = Date().addingTimeInterval(-86400 * 7) } }
            }
        }
    }

    // MARK: - Results

    private var resultsSection: some View {
        VStack(spacing: GlassTheme.Space.l) {
            if let answer {
                GlassCard {
                    HStack(alignment: .top, spacing: GlassTheme.Space.m) {
                        Image(systemName: "sparkles")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(GlassTheme.accent)
                        Text(answer)
                            .font(.body)
                            .foregroundStyle(GlassTheme.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: GlassTheme.Space.l) {
                    SectionHeader("Results") {
                        HStack(spacing: GlassTheme.Space.s) {
                            Text("\(results.count)")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(GlassTheme.secondary)
                            if resultsRanked {
                                // Semantic results are best-match-first; surface that instead
                                // of a time-sort toggle that would scramble the ranking.
                                Label("Best match", systemImage: "sparkles")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(GlassTheme.accent)
                            } else {
                                Button {
                                    Haptics.select()
                                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { sortNewest.toggle() }
                                } label: {
                                    Image(systemName: sortNewest ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                                        .font(.title3.weight(.regular))
                                        .foregroundStyle(GlassTheme.accent)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Sort order")
                                .accessibilityValue(sortNewest ? "Newest first" : "Oldest first")
                            }
                        }
                    }

                    if let error = errorMessage {
                        VStack(spacing: GlassTheme.Space.m) {
                            EmptyStateView(
                                icon: "exclamationmark.triangle",
                                title: "Search Failed",
                                message: error
                            )
                            Button {
                                Haptics.tap()
                                Task { await performSearch() }
                            } label: {
                                Label("Try Again", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
                        }
                        .frame(maxWidth: .infinity)
                    } else if results.isEmpty {
                        VStack(spacing: GlassTheme.Space.m) {
                            EmptyStateView(
                                icon: "magnifyingglass",
                                title: "No matches",
                                message: "No events match your search."
                            )
                            if hasActiveFilters {
                                Button {
                                    Haptics.tap()
                                    clearFilters()
                                    Task { await performSearch() }
                                } label: {
                                    Label("Clear Filters", systemImage: "xmark.circle.fill")
                                }
                                .buttonStyle(PillButtonStyle(tint: GlassTheme.accent))
                            }
                        }
                        .frame(maxWidth: .infinity)
                    } else if resultsRanked {
                        // Ranked semantic results render as rich rows so the GenAI
                        // description and match source ride alongside each hit.
                        LazyVStack(spacing: GlassTheme.Space.s) {
                            ForEach(displayResults) { event in
                                Button { Haptics.tap(); path.append(event) } label: {
                                    searchResultRow(event)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: GlassTheme.Space.s)], spacing: GlassTheme.Space.s) {
                            ForEach(displayResults) { event in
                                Button { Haptics.tap(); path.append(event) } label: {
                                    thumbnail(event)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            icon: "sparkle.magnifyingglass",
            title: "Nothing tracked yet",
            message: "Detected objects will appear here grouped by type."
        )
        .padding(.top, 40)
    }

    private func filterChip(_ title: String, icon: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { Haptics.select(); action() } label: {
            HStack(spacing: GlassTheme.Space.xs) {
                if let icon {
                    Image(systemName: icon).font(.caption.weight(.medium))
                }
                Text(title).font(.subheadline.weight(.medium))
            }
            .foregroundStyle(selected ? Color.white : GlassTheme.primary)
            .padding(.horizontal, GlassTheme.Space.m)
            .padding(.vertical, GlassTheme.Space.s)
            .background(
                selected ? AnyShapeStyle(GlassTheme.accent) : AnyShapeStyle(GlassTheme.surfaceHigh),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(GlassTheme.separator, lineWidth: selected ? 0 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Data

    private func loadBrowse() async {
        guard let client = appState.client else { return }
        loadingBrowse = true
        defer { loadingBrowse = false }
        // Pull a deep window so every sub-label (Amazon, FedEx, your truck, faces) surfaces.
        if let fetched = try? await client.events(limit: 600) {
            browseEvents = fetched
        } else if browseEvents.isEmpty {
            // Only fall back to live events when we have nothing — a transient refresh
            // failure shouldn't wipe a list the user is already looking at.
            browseEvents = appState.events
        }
        rebuildGroups()
    }

    private var hasActiveFilters: Bool {
        selectedCamera != "all" || selectedLabel != "all" || selectedSubLabel != "all"
            || selectedZone != "all" || afterDate != nil
            || !plateQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func clearFilters() {
        selectedCamera = "all"
        selectedLabel = "all"
        selectedSubLabel = "all"
        selectedZone = "all"
        afterDate = nil
        plateQuery = ""
    }

    private func performSearch() async {
        guard let client = appState.client else { return }
        // Re-entrancy guard: repeated Return taps fire overlapping multi-request searches
        // that race on shared @State (results/answer). Ignore submits while one is running.
        guard !isSearching else { return }
        isSearching = true
        hasSearched = true
        errorMessage = nil
        answer = nil
        resultsRanked = false
        defer { isSearching = false }

        // Only the filters the user explicitly set in the panel.
        let fCamera = selectedCamera == "all" ? nil : selectedCamera
        let fLabel = selectedLabel == "all" ? nil : selectedLabel
        let subLabel = selectedSubLabel == "all" ? nil : selectedSubLabel
        let zone = selectedZone == "all" ? nil : selectedZone
        let q = query.trimmingCharacters(in: .whitespaces)

        do {
            var found: [FrigateEvent]

            if q.isEmpty {
                // Pure filter browse.
                found = try await client.events(
                    camera: fCamera, label: fLabel, subLabel: subLabel,
                    zone: zone, after: afterDate, limit: 300
                )
            } else if isQuestion(q) {
                // A question ("how many packages today", "when was the dog out") — parse it
                // into structured filters so counts/times are precise, then answer.
                let plan = AskParser.interpret(q, cameras: appState.cameras.map(\.name), faceNames: faceNames, style: .default)
                found = (try await client.events(
                    camera: fCamera ?? plan.camera, label: fLabel ?? plan.label,
                    subLabel: subLabel, zone: zone,
                    after: afterDate ?? plan.after, before: plan.before, limit: 200
                )).filter { plan.matches($0, style: .default) }
                answer = AskParser.answer(for: plan, results: found.sorted { ($0.startTime ?? 0) > ($1.startTime ?? 0) })
            } else {
                // A description ("kid on a bike", "blue car", "Amazon"). Run ALL three
                // matchers and merge — so we never come back empty when matching events
                // exist, regardless of whether the server has semantic search enabled:
                //   1. Frigate semantic search (visual + GenAI description) — best match.
                //   2. Exact sub-label/object hits (Amazon/FedEx/a person's name/"car").
                //   3. On-device keyword ranker over a broad recent set (kid→person,
                //      bike→bicycle, blue/car token match) — the reliable safety net.
                async let semanticTask = client.safeSemanticSearch(
                    query: q, camera: fCamera, label: fLabel,
                    subLabel: subLabel, zone: zone, after: afterDate, limit: 300
                )
                let exact = await exactMatches(q, client: client, camera: fCamera, zone: zone)
                let keyword = await keywordFallback(
                    q, client: client,
                    camera: fCamera, label: fLabel, subLabel: subLabel, zone: zone
                )
                let semantic = await semanticTask

                var merged: [FrigateEvent] = []
                var seen = Set<String>()
                func add(_ list: [FrigateEvent]) {
                    for event in list where !seen.contains(event.id) { seen.insert(event.id); merged.append(event) }
                }
                add(semantic)   // best-match first when the server supports it
                add(exact)      // precise carrier/face/object hits
                add(keyword)    // on-device relevance — guarantees results when matches exist

                // Last resort: nothing matched the recent pool — query the implied object
                // labels directly (e.g. "kid on a bike" → all person + bicycle events),
                // which can reach further back than the mixed recent set.
                if merged.isEmpty {
                    for label in AskParser.impliedLabels(in: q) {
                        let evs = (try? await client.events(
                            camera: fCamera, label: label, zone: zone, after: afterDate, limit: 100
                        )) ?? []
                        add(evs)
                    }
                }
                found = merged
                resultsRanked = true
            }

            // Optional license-plate filter from the panel.
            let plate = plateQuery.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !plate.isEmpty {
                found = found.filter { ($0.recognizedLicensePlate ?? "").uppercased().contains(plate) }
            }

            results = found
            // Tactile confirmation the search finished: a soft success for hits, a
            // gentle warning when nothing matched.
            if found.isEmpty { Haptics.warning() } else { Haptics.success() }
        } catch {
            if !error.isCancellation {
                errorMessage = error.localizedDescription
            }
            results = []
            Haptics.error()
        }
    }

    /// Exact sub-label / object-label matches for a query, honoring the panel's
    /// camera/zone/date filters. Lets "Amazon", "FedEx", a person's name, "car",
    /// "package", etc. pull their precise events alongside the semantic best-matches.
    private func exactMatches(_ q: String, client: FrigateClient, camera: String?, zone: String?) async -> [FrigateEvent] {
        let lower = q.trimmingCharacters(in: .whitespaces).lowercased()
        guard !lower.isEmpty else { return [] }
        var out: [FrigateEvent] = []
        var seen = Set<String>()
        func add(_ events: [FrigateEvent]) {
            for e in events where !seen.contains(e.id) { seen.insert(e.id); out.append(e) }
        }
        // Sub-label (carriers like Amazon/FedEx/UPS, recognized faces, named plates).
        if let sub = appState.subLabels.first(where: { $0.caseInsensitiveCompare(lower) == .orderedSame }) {
            add((try? await client.events(camera: camera, subLabel: sub, zone: zone, after: afterDate, limit: 200)) ?? [])
        }
        // Object label (person, car, package…) when the query names one exactly.
        let knownLabels = Set((appState.labels + appState.events.map(\.label)).map { $0.lowercased() })
        if knownLabels.contains(lower) {
            add((try? await client.events(camera: camera, label: lower, zone: zone, after: afterDate, limit: 150)) ?? [])
        }
        return out.sorted { ($0.startTime ?? 0) > ($1.startTime ?? 0) }
    }

    /// On-device relevance fallback for descriptive queries when Frigate semantic
    /// search isn't enabled (or returns nothing). Pulls a broad recent set honoring
    /// only the explicit panel filters, then ranks each event by how well its label,
    /// sub-label, recognized face/plate, camera and zones match the query words —
    /// expanding object synonyms ("kid" → person, "bike" → bicycle) so natural
    /// descriptions surface every relevant detection instead of dead-ending.
    private func keywordFallback(
        _ q: String, client: FrigateClient,
        camera: String?, label: String?, subLabel: String?, zone: String?
    ) async -> [FrigateEvent] {
        let pool = (try? await client.events(
            camera: camera, label: label, subLabel: subLabel, zone: zone,
            after: afterDate, limit: 600
        )) ?? []

        let implied = Set(AskParser.impliedLabels(in: q))
        let stop: Set<String> = ["on", "the", "and", "with", "near", "around", "was", "were",
                                 "any", "all", "for", "from", "out", "off", "did", "has", "have"]
        let tokens = q.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stop.contains($0) }

        // Nothing usable to match on → just show the recent pool rather than a dead end.
        if implied.isEmpty && tokens.isEmpty { return pool }

        func score(_ e: FrigateEvent) -> Int {
            var s = 0
            if implied.contains(e.label.lowercased()) { s += 4 }
            let hay = ([e.label, e.displayLabel, e.subLabel, e.recognizedFace,
                        e.camera.replacingOccurrences(of: "_", with: " "),
                        e.recognizedLicensePlate].compactMap { $0 } + (e.zones ?? []))
                .joined(separator: " ").lowercased()
            for t in tokens where hay.contains(t) { s += 1 }
            return s
        }

        return pool
            .compactMap { e -> (FrigateEvent, Int)? in
                let s = score(e); return s > 0 ? (e, s) : nil
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : ($0.0.startTime ?? 0) > ($1.0.startTime ?? 0) }
            .map(\.0)
    }

    private func isQuestion(_ q: String) -> Bool {
        let l = q.lowercased()
        if l.hasSuffix("?") { return true }
        let starters = ["how ", "when ", "did ", "was ", "is ", "are ", "any ", "who "]
        if starters.contains(where: l.hasPrefix) { return true }
        return l.contains("how many") || l.contains("last seen") || l.contains("when did")
    }
}
