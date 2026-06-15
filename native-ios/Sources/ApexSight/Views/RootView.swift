import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if appState.session == nil {
            LoginView()
        } else {
            MainTabView()
        }
    }
}
