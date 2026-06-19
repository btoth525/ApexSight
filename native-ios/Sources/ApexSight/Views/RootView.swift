import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        Group {
            if !hasCompletedOnboarding {
                OnboardingView()
            } else if !appState.accountSignedIn {
                // Sign in to your ApexSight account first — like every other app.
                AccountSignInView()
            } else if appState.session == nil {
                // Signed in, but no Frigate saved yet (or still connecting) → let them add it.
                LoginView()
            } else {
                MainTabView()
            }
        }
        .transition(.opacity)
        .task(id: appState.accountSignedIn) {
            // After sign-in (and on cold launch with a saved account), pull the Frigate
            // server from the account and connect automatically — no setup in the app.
            if appState.accountSignedIn && appState.session == nil {
                await appState.bootstrapFromAccount()
            }
        }
    }
}
