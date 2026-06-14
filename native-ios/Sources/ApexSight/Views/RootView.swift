import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    GlassTheme.background,
                    Color(red: 0.03, green: 0.05, blue: 0.08),
                    GlassTheme.background
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if appState.session == nil {
                LoginView()
            } else {
                DashboardView()
            }
        }
    }
}
