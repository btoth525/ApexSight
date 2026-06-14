import SwiftUI

@main
struct ApexSightApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var notificationDelegate = NotificationResponseDelegate()

    init() {
        NativeNotificationManager.registerCategories()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
                .onAppear {
                    notificationDelegate.configure(appState: appState)
                }
                .onOpenURL { url in
                    appState.handleDeepLink(url)
                }
        }
    }
}
