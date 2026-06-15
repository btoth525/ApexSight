import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var appState: AppState
    @State private var query = ""
    @State private var selectedCamera = "all"
    @State private var selectedLabel = "all"
    @State private var selectedSubLabel = "all"
    @State private var selectedZone = "all"
    @State private var afterDate: Date? = nil
    @State private var showDateFilter = false
    @State private var showFilters = false
    @State private var results: [FrigateEvent] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var errorMessage: String?
    @State private var useSemanticSearch = false
    @State private var plateQuery = ""
    @State private var sortNewest = true
    @State private var path = NavigationPath()

    // Browse view (default state): a larger recent set grouped by object.
    @State private var browseEvents: [FrigateEvent] = []
    @State private var loadingBrowse = false

    private var sortedResults: [FrigateEvent] {
        sortNewest
            ? results.sorted { ($0.startTime ?? 0) > ($1.startTime ?? 0) }
            : results.sorted { ($0.startTime ?? 0) < ($1.startTime ?? 0) }
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
                    VStack(alignment: .leading, spacing: 16) {
                        searchBar
                        if showFilters { filterSection }
                        if showDateFilter { dateFilterCard }

                        if isSearching {
                            HStack { Spacer(); ProgressView().tint(GlassTheme.cyan); Spacer() }
                                .padding(.top, 40)
                        } else if hasSearched {
                            resultsSection
                        } else {
                            browseSection
                        }
                    }
                    .padding(18)
                }
                .refreshable { await loadBrowse() }
            }
            .navigationTitle("Explore")
            .navigationBarTitleDisplayMode(.inline)
            .glassNavBar()
            .navigationDestination(for: FrigateEvent.self) { event in
                EventDetailView(event: event)
            }
            .task { if browseEvents.isEmpty { await loadBrowse() } }
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        GlassCard {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(GlassTheme.cyan)

                    TextField("Search footage…", text: $query)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(GlassTheme.primary)
                        .submitLabel(.search)
                        .onSubmit { Task { await performSearch() } }

                    if !query.isEmpty || hasSearched {
                        Button {
                            query = ""
                            results = []
                            hasSearched = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(GlassTheme.secondary)
                        }
                    }
                }

                HStack {
                    Toggle(isOn: $useSemanticSearch) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 13, weight: .heavy))
                            Text("AI Search")
                                .font(.system(size: 13, weight: .heavy))
                        }
                        .foregroundStyle(useSemanticSearch ? GlassTheme.cyan : GlassTheme.secondary)
                    }
                    .tint(GlassTheme.cyan)
                    .fixedSize()

                    Spacer()

                    Button {
                        withAnimation { showFilters.toggle() }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle\(showFilters ? ".fill" : "")")
                            .font(.system(size: 20, weight: .black))
                            .foregroundStyle(GlassTheme.cyan)
                    }

                    Button {
                        Task { await performSearch() }
                    } label: {
                        Text("Search")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(GlassTheme.cyan, in: Capsule())
                    }
                    .disabled(isSearching)
                }

                if useSemanticSearch {
                    Text("Describe what you saw — “person in a red shirt”, “delivery truck at night”.")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(GlassTheme.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
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

    private var objectGroups: [ObjectGroup] {
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

        return labelGroups + subGroups
    }

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            if loadingBrowse && browseEvents.isEmpty {
                HStack { Spacer(); ProgressView().tint(GlassTheme.cyan); Spacer() }
                    .padding(.top, 40)
            } else if objectGroups.isEmpty {
                emptyState
            } else {
                ForEach(objectGroups) { group in
                    groupRow(group)
                }
            }
        }
    }

    private func groupRow(_ group: ObjectGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                selectedLabel = group.label ?? "all"
                selectedSubLabel = group.subLabel ?? "all"
                Task { await performSearch() }
            } label: {
                HStack(spacing: 8) {
                    Text("\(group.emoji) \(group.title)")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(GlassTheme.primary)
                    Text("\(group.events.count)")
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(GlassTheme.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.08), in: Capsule())
                    Spacer()
                    HStack(spacing: 3) {
                        Text("See all")
                            .font(.system(size: 12, weight: .heavy))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .black))
                    }
                    .foregroundStyle(GlassTheme.cyan)
                }
            }
            .buttonStyle(.plain)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(group.events.prefix(8)) { event in
                        Button { path.append(event) } label: {
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
                RemoteImage(url: url, contentMode: .fill)
                    .frame(width: 104, height: 104)
                    .clipped()
            } else {
                Color.black.frame(width: 104, height: 104)
            }
            if let start = event.startTime {
                Text(Date(timeIntervalSince1970: start).formatted(.relative(presentation: .numeric)))
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(5)
            }
        }
        .frame(width: 104, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
    }

    // MARK: - Filters

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
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

            HStack(spacing: 10) {
                Image(systemName: "car.fill")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(GlassTheme.purple)
                TextField("License plate (optional)", text: $plateQuery)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(GlassTheme.primary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .submitLabel(.search)
                    .onSubmit { Task { await performSearch() } }
            }
            .padding(12)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                withAnimation { showDateFilter.toggle() }
                if !showDateFilter { afterDate = nil }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showDateFilter ? "calendar.badge.minus" : "calendar.badge.plus")
                        .font(.system(size: 14, weight: .heavy))
                    Text(afterDate.map { "From: \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Date Filter")
                        .font(.system(size: 13, weight: .heavy))
                }
                .foregroundStyle(showDateFilter ? GlassTheme.cyan : GlassTheme.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background((showDateFilter ? GlassTheme.cyan : Color.white).opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
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
            VStack(alignment: .leading, spacing: 10) {
                Text("Events After")
                    .font(.system(size: 14, weight: .black))
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
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Results")
                        .font(.system(size: 21, weight: .black))
                        .foregroundStyle(GlassTheme.primary)
                    Spacer()
                    Text("\(results.count)")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(GlassTheme.secondary)
                    Button { sortNewest.toggle() } label: {
                        Image(systemName: sortNewest ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(GlassTheme.cyan)
                    }
                    .buttonStyle(.plain)
                }

                if let error = errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(GlassTheme.orange)
                }

                if results.isEmpty && errorMessage == nil {
                    Text("No events match your search.")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(GlassTheme.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                        ForEach(sortedResults) { event in
                            Button { path.append(event) } label: {
                                thumbnail(event)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 48, weight: .black))
                .foregroundStyle(GlassTheme.secondary.opacity(0.4))
            Text("Nothing tracked yet")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(GlassTheme.secondary)
            Text("Detected objects will appear here grouped by type.")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(GlassTheme.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func filterChip(_ title: String, icon: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 11, weight: .heavy))
                }
                Text(title).font(.system(size: 12, weight: .black))
            }
            .foregroundStyle(selected ? Color.black : GlassTheme.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? GlassTheme.cyan : .white.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Data

    private func loadBrowse() async {
        guard let client = appState.client else { return }
        loadingBrowse = true
        browseEvents = (try? await client.events(limit: 240)) ?? appState.events
        loadingBrowse = false
    }

    private func performSearch() async {
        guard let client = appState.client else { return }
        isSearching = true
        hasSearched = true
        errorMessage = nil
        defer { isSearching = false }

        let camera = selectedCamera == "all" ? nil : selectedCamera
        let label = selectedLabel == "all" ? nil : selectedLabel
        let subLabel = selectedSubLabel == "all" ? nil : selectedSubLabel
        let zone = selectedZone == "all" ? nil : selectedZone

        do {
            if useSemanticSearch && !query.isEmpty {
                results = try await client.semanticSearch(
                    query: query, camera: camera, label: label,
                    subLabel: subLabel, zone: zone, after: afterDate
                )
            } else {
                results = try await client.events(
                    camera: camera, label: label, subLabel: subLabel,
                    zone: zone, after: afterDate, limit: 100
                )
            }

            let plate = plateQuery.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !plate.isEmpty {
                results = results.filter { ($0.recognizedLicensePlate ?? "").uppercased().contains(plate) }
            }
        } catch {
            errorMessage = error.localizedDescription
            results = []
        }
    }
}
