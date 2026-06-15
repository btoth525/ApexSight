import SwiftUI
import AVFoundation

@main
struct ApexSightApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var notificationDelegate = NotificationResponseDelegate()
    @AppStorage("colorSchemePreference") private var colorSchemePreference = "dark"

    init() {
        NativeNotificationManager.registerCategories()
        configureAudioSession()
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    private var preferredColorScheme: ColorScheme? {
        switch colorSchemePreference {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .preferredColorScheme(preferredColorScheme)
                .onAppear {
                    notificationDelegate.configure(appState: appState)
                }
                .onOpenURL { url in
                    appState.handleDeepLink(url)
                }
        }
    }
}
