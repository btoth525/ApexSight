import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            GlassBackground()

            if appState.session == nil {
                LoginView()
            } else {
                DashboardView()
            }
        }
    }
}
