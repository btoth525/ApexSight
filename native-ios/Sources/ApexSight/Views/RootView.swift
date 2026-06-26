import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !hasCompletedOnboarding {
                OnboardingView()
                    .transition(.opacity)
            } else if appState.session == nil {
                LoginView()
                    .transition(.opacity)
            } else {
                MainTabView()
                    .transition(.opacity)
            }
        }
        // Crossfade between onboarding, login, and the signed-in app so the hand-offs
        // (finishing onboarding, connecting, signing out) feel deliberate rather than abrupt.
        // Reduce Motion swaps the screens instantly rather than fading.
        .animation(handoff, value: hasCompletedOnboarding)
        .animation(handoff, value: appState.session == nil)
    }

    private var handoff: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.3)
    }
}
