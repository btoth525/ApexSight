import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedTab: Tab? = .cameras
    @State private var detailSheet: DetailSheet?
    @State private var deepLinkTask: Task<Void, Never>?

    enum Tab: Int, Hashable, CaseIterable, Identifiable {
        case cameras, review, activity, explore, settings
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .cameras:  return "Cameras"
            case .review:   return "Review"
            case .activity: return "Activity"
            case .explore:  return "Explore"
            case .settings: return "Settings"
            }
        }
        var icon: String {
            switch self {
            case .cameras:  return "video.fill"
            case .review:   return "bell.badge.fill"
            case .activity: return "list.bullet.rectangle.portrait.fill"
            case .explore:  return "magnifyingglass"
            case .settings: return "gearshape.fill"
            }
        }
    }

    private enum DetailSheet: Identifiable {
        case event(FrigateEvent)
        case review(FrigateReviewItem)
        case camera(FrigateCamera)

        var id: String {
            switch self {
            case .event(let event): return "event-\(event.id)"
            case .review(let review): return "review-\(review.id)"
            case .camera(let camera): return "camera-\(camera.name)"
            }
        }
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                sidebarLayout
            } else {
                tabLayout
            }
        }
        .tint(GlassTheme.accent)
        .sensoryFeedback(.selection, trigger: selectedTab)
        // A soft tick when a deep link (push tap / in-app banner) surfaces a detail sheet,
        // so the jump registers tactically.
        .sensoryFeedback(.impact(weight: .light), trigger: detailSheet?.id) { old, new in
            old == nil && new != nil
        }
        .sheet(item: $detailSheet) { sheet in
            NavigationStack {
                switch sheet {
                case .event(let event): EventDetailView(event: event)
                case .review(let review): ReviewDetailView(review: review)
                case .camera(let camera): LiveStreamView(camera: camera)
                }
            }
            .environmentObject(appState)
            .preferredColorScheme(.dark)
            // Native grabber on the detail sheets; the live player is immersive, so no grabber.
            .presentationDragIndicator({ if case .camera = sheet { return .hidden } else { return .visible } }())
        }
        .onChange(of: appState.deepLink) { _, route in
            handleDeepLink(route)
        }
        .task {
            // Catch a deep link set before this view started observing (cold launch from a push).
            if appState.deepLink != nil { handleDeepLink(appState.deepLink) }
        }
    }

    // MARK: - Layouts

    private var tabLayout: some View {
        TabView(selection: Binding(
            get: { selectedTab ?? .cameras },
            set: { selectedTab = $0 }
        )) {
            ForEach(Tab.allCases) { tab in
                view(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.icon) }
                    .badge(tab == .review ? appState.unreviewedCount : 0)
                    .tag(tab)
            }
        }
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarColorScheme(.dark, for: .tabBar)
        // iOS 26: the Liquid Glass tab bar shrinks away as you scroll the cameras,
        // giving the content even more room — then returns on scroll-up.
        .modifier(TabBarMinimizeOnScroll())
    }

    private var sidebarLayout: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Label(tab.title, systemImage: tab.icon)
                        .font(.body.weight(.semibold))
                        .badge(tab == .review ? appState.unreviewedCount : 0)
                        .tag(tab)
                }
            }
            .navigationTitle("ApexSight")
            .glassNavBar()
            .preferredColorScheme(.dark)
        } detail: {
            view(for: selectedTab ?? .cameras)
                .id(selectedTab)
        }
    }

    @ViewBuilder
    private func view(for tab: Tab) -> some View {
        switch tab {
        case .cameras:  CamerasTab()
        case .review:   ReviewTab()
        case .activity: ActivityTab()
        case .explore:  SearchView()
        case .settings: SettingsTab()
        }
    }

    // MARK: - Deep links

    private func handleDeepLink(_ route: AppDeepLink?) {
        guard let route else { return }
        switch route {
        case .camera(let name):
            selectedTab = .cameras
            if let camera = appState.cameras.first(where: { $0.name == name }) {
                detailSheet = .camera(camera)
            } else {
                // Cold launch straight into a deep link: the camera list may not be
                // loaded yet. Fetch it (with retry) so the tile still opens.
                resolveDeepLink {
                    (try? await appState.client?.cameras())?.first { $0.name == name }.map { .camera($0) }
                }
            }
        case .review(let id):
            selectedTab = .review
            if let review = appState.reviews.first(where: { $0.id == id }) {
                detailSheet = .review(review)
            } else {
                resolveDeepLink {
                    (try? await appState.client?.review(id: id)).map { .review($0) }
                }
            }
        case .event(let id):
            selectedTab = .activity
            if let event = appState.events.first(where: { $0.id == id }) {
                detailSheet = .event(event)
            } else {
                resolveDeepLink {
                    (try? await appState.client?.event(id: id)).map { .event($0) }
                }
            }
        }
        appState.deepLink = nil
    }

    /// Resolve a deep link's target by fetching it, retrying with backoff. A push tap
    /// often lands while the network is still coming up (phone just woke), so a single
    /// attempt can silently fail and the alert never opens — retry a few times instead.
    private func resolveDeepLink(_ fetch: @escaping () async -> DetailSheet?) {
        deepLinkTask?.cancel()
        deepLinkTask = Task {
            for attempt in 0..<4 where detailSheet == nil {
                if Task.isCancelled { return }
                if let sheet = await fetch() {
                    detailSheet = sheet
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(800_000_000 * (attempt + 1)))
            }
        }
    }
}

/// iOS 26: shrink the Liquid Glass tab bar as the user scrolls down (more content room),
/// restoring it on scroll-up. No-op on earlier systems.
private struct TabBarMinimizeOnScroll: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}
