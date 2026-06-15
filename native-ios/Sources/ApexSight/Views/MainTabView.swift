import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab = 0

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
        .onChange(of: appState.deepLink) { _, route in
            guard let route else { return }
            switch route {
            case .review: selectedTab = 1
            case .event: selectedTab = 2
            case .camera: selectedTab = 0
            }
            appState.deepLink = nil
        }
    }
}
