import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        if !hasCompletedOnboarding {
            OnboardingView()
                .transition(.opacity)
        } else if appState.session == nil {
            LoginView()
                .transition(.opacity)
        } else {
            MainTabView()
        }
    }
}
