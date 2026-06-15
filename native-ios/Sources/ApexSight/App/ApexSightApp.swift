import SwiftUI
import AVFoundation

@main
struct ApexSightApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var notificationDelegate = NotificationResponseDelegate()
    @AppStorage("colorSchemePreference") private var colorSchemePreference = "dark"
    @Environment(\.scenePhase) private var scenePhase

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
                .overlay(alignment: .top) {
                    LiveAlertBanner()
                        .environmentObject(appState)
                }
                .preferredColorScheme(preferredColorScheme)
                .onAppear {
                    notificationDelegate.configure(appState: appState)
                }
                .onOpenURL { url in
                    appState.handleDeepLink(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        appState.startRealtime()
                    case .background:
                        appState.stopRealtime()
                        BackgroundRefreshManager.schedule()
                    default:
                        break
                    }
                }
        }
    }
}
