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
    @State private var results: [FrigateEvent] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var errorMessage: String?
    @State private var useSemanticSearch = false
    @State private var path = NavigationPath()

    private var allLabels: [String] {
        Array(Set(appState.labels + appState.events.map(\.label))).sorted()
    }

    private var allSubLabels: [String] {
        Array(Set(appState.subLabels)).sorted()
    }

    private var allZones: [String] {
        Array(Set(appState.cameras.flatMap(\.zones))).sorted()
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                GlassBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Search header
                        searchBar

                        // Filters
                        filterSection

                        // Date filter
                        if showDateFilter {
                            dateFilterCard
                        }

                        // Results
                        if isSearching {
                            HStack {
                                Spacer()
                                ProgressView().tint(GlassTheme.cyan)
                                Spacer()
                            }
                            .padding(.top, 40)
                        } else if hasSearched {
                            resultsSection
                        } else {
                            emptyState
                        }
                    }
                    .padding(18)
                }
            }
            .navigationTitle("Explore")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: FrigateEvent.self) { event in
                EventDetailView(event: event)
            }
        }
    }

    private var searchBar: some View {
        GlassCard {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(GlassTheme.cyan)

                    TextField("Search footage...", text: $query)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(GlassTheme.primary)
                        .submitLabel(.search)
                        .onSubmit { Task { await performSearch() } }

                    if !query.isEmpty {
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
                            Image(systemName: "brain")
                                .font(.system(size: 13, weight: .heavy))
                            Text("Semantic Search")
                                .font(.system(size: 13, weight: .heavy))
                        }
                        .foregroundStyle(GlassTheme.secondary)
                    }
                    .tint(GlassTheme.cyan)

                    Spacer()

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
            }
        }
    }

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Camera chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip("All Cameras", icon: "video", selected: selectedCamera == "all") {
                        selectedCamera = "all"
                    }
                    ForEach(appState.cameras) { camera in
                        filterChip(titleize(camera.name), icon: nil, selected: selectedCamera == camera.name) {
                            selectedCamera = camera.name
                        }
                    }
                }
            }

            // Label chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip("All Labels", icon: "tag", selected: selectedLabel == "all") {
                        selectedLabel = "all"
                    }
                    ForEach(allLabels, id: \.self) { label in
                        filterChip("\(NotificationCopy.emoji(for: label)) \(titleize(label))", icon: nil, selected: selectedLabel == label) {
                            selectedLabel = label
                        }
                    }
                }
            }

            // Sub-label chips (only if any exist)
            if !allSubLabels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filterChip("All Sub-Labels", icon: "tag.fill", selected: selectedSubLabel == "all") {
                            selectedSubLabel = "all"
                        }
                        ForEach(allSubLabels, id: \.self) { sub in
                            filterChip("\(NotificationCopy.emoji(for: "", subLabel: sub)) \(titleize(sub))", icon: nil, selected: selectedSubLabel == sub) {
                                selectedSubLabel = sub
                            }
                        }
                    }
                }
            }

            // Zone chips (only if any)
            if !allZones.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filterChip("All Zones", icon: "mappin", selected: selectedZone == "all") {
                            selectedZone = "all"
                        }
                        ForEach(allZones, id: \.self) { zone in
                            filterChip(titleize(zone), icon: nil, selected: selectedZone == zone) {
                                selectedZone = zone
                            }
                        }
                    }
                }
            }

            // Date toggle
            Button {
                withAnimation { showDateFilter.toggle() }
                if !showDateFilter { afterDate = nil }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showDateFilter ? "calendar.badge.minus" : "calendar.badge.plus")
                        .font(.system(size: 14, weight: .heavy))
                    Text(afterDate != nil ? "From: \(afterDate!.formatted(date: .abbreviated, time: .omitted))" : "Date Filter")
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

    private var resultsSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Results")
                        .font(.system(size: 21, weight: .black))
                        .foregroundStyle(GlassTheme.primary)
                    Spacer()
                    Text("\(results.count) events")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(GlassTheme.secondary)
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
                    VStack(spacing: 10) {
                        ForEach(results) { event in
                            Button {
                                path.append(event)
                            } label: {
                                EventRow(event: event)
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
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48, weight: .black))
                .foregroundStyle(GlassTheme.secondary.opacity(0.4))
            Text("Search your footage")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(GlassTheme.secondary)
            Text("Filter by camera, object, zone, or use\nsemantic search to describe what you saw.")
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
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .heavy))
                }
                Text(title)
                    .font(.system(size: 12, weight: .black))
            }
            .foregroundStyle(selected ? Color.black : GlassTheme.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(selected ? GlassTheme.cyan : .white.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
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
                    query: query,
                    camera: camera,
                    label: label,
                    subLabel: subLabel,
                    zone: zone,
                    after: afterDate
                )
            } else {
                results = try await client.events(
                    camera: camera,
                    label: label,
                    subLabel: subLabel,
                    zone: zone,
                    after: afterDate
                )
            }
        } catch {
            errorMessage = error.localizedDescription
            results = []
        }
    }
}
