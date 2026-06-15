import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedTab: Tab? = .cameras
    @State private var detailSheet: DetailSheet?

    enum Tab: Int, Hashable, CaseIterable, Identifiable {
        case cameras, review, activity, explore, settings
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .cameras: return "Cameras"
            case .review: return "Review"
            case .activity: return "Activity"
            case .explore: return "Explore"
            case .settings: return "Settings"
            }
        }
        var icon: String {
            switch self {
            case .cameras: return "video.fill"
            case .review: return "bell.badge.fill"
            case .activity: return "list.bullet.rectangle.portrait.fill"
            case .explore: return "magnifyingglass"
            case .settings: return "gearshape.fill"
            }
        }
    }

    private enum DetailSheet: Identifiable {
        case event(FrigateEvent)
        case review(FrigateReviewItem)

        var id: String {
            switch self {
            case .event(let event): return "event-\(event.id)"
            case .review(let review): return "review-\(review.id)"
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
        .tint(GlassTheme.cyan)
        .sheet(item: $detailSheet) { sheet in
            NavigationStack {
                switch sheet {
                case .event(let event): EventDetailView(event: event)
                case .review(let review): ReviewDetailView(review: review)
                }
            }
            .environmentObject(appState)
            .preferredColorScheme(.dark)
        }
        .onChange(of: appState.deepLink) { _, route in
            handleDeepLink(route)
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
                    .tag(tab)
            }
        }
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarColorScheme(.dark, for: .tabBar)
    }

    private var sidebarLayout: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Label(tab.title, systemImage: tab.icon)
                        .font(.system(size: 16, weight: .heavy))
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
        case .cameras: CamerasTab()
        case .review: ReviewTab()
        case .activity: ActivityTab()
        case .explore: SearchView()
        case .settings: SettingsTab()
        }
    }

    // MARK: - Deep links

    private func handleDeepLink(_ route: AppDeepLink?) {
        guard let route else { return }
        switch route {
        case .camera:
            selectedTab = .cameras
        case .review(let id):
            selectedTab = .review
            if let review = appState.reviews.first(where: { $0.id == id }) {
                detailSheet = .review(review)
            }
        case .event(let id):
            selectedTab = .activity
            if let event = appState.events.first(where: { $0.id == id }) {
                detailSheet = .event(event)
            } else {
                Task {
                    if let event = try? await appState.client?.event(id: id) {
                        detailSheet = .event(event)
                    }
                }
            }
        }
        appState.deepLink = nil
    }
}
