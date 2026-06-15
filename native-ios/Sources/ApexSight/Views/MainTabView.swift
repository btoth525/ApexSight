import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab = 0
    @State private var detailSheet: DetailSheet?

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
        TabView(selection: $selectedTab) {
            CamerasTab()
                .tabItem { Label("Cameras", systemImage: "video.fill") }
                .tag(0)
            ReviewTab()
                .tabItem { Label("Review", systemImage: "bell.badge.fill") }
                .tag(1)
            ActivityTab()
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle.portrait.fill") }
                .tag(2)
            SearchView()
                .tabItem { Label("Explore", systemImage: "magnifyingglass") }
                .tag(3)
            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(4)
        }
        .tint(GlassTheme.cyan)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .toolbarColorScheme(.dark, for: .tabBar)
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

    private func handleDeepLink(_ route: AppDeepLink?) {
        guard let route else { return }
        switch route {
        case .camera:
            selectedTab = 0
        case .review(let id):
            selectedTab = 1
            if let review = appState.reviews.first(where: { $0.id == id }) {
                detailSheet = .review(review)
            }
        case .event(let id):
            selectedTab = 2
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
