import SwiftUI
import AVFoundation

@main
struct ApexSightApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var notificationDelegate = NotificationResponseDelegate()
    @StateObject private var appLock = AppLockController()
    @AppStorage("colorSchemePreference") private var colorSchemePreference = "dark"
    @Environment(\.scenePhase) private var scenePhase

    init() {
        NativeNotificationManager.registerCategories()
        // NOTE: the audio session is intentionally NOT activated here. Activating .playback at
        // launch interrupts/ducks the user's music or podcast before any video even plays (and
        // live video defaults to muted). The clip player and live unmute take the session on
        // demand, only when there's actually audio to play.
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
                // Feel a new in-app alert the instant its banner appears (not on dismiss).
                .sensoryFeedback(trigger: appState.liveBanner?.id) { _, new in
                    new != nil ? .warning : nil
                }
                .overlay(alignment: .top) {
                    OfflineBanner()
                        .environmentObject(appState)
                }
                // Face ID / passcode privacy cover — only visible when the user enabled
                // the lock and the app is locked (launch / return from background).
                .overlay {
                    if appLock.isLocked {
                        LockOverlayView { appLock.unlock() }
                            .transition(.opacity)
                    }
                }
                .preferredColorScheme(preferredColorScheme)
                .onAppear {
                    notificationDelegate.configure(appState: appState)
                }
                .task {
                    // Start polling immediately on cold launch for already-signed-in users.
                    // .onChange(of: scenePhase) doesn't fire for the initial .active value,
                    // so this ensures the live stream and 15s poller start right away.
                    appState.startRealtime()
                    appState.startForegroundPolling()
                    appState.consumePendingIntentLink()
                    // Register for push + (re)send the token to the relay on launch.
                    PushRegistrar.ensureRegistered()
                    // Stream the Live Activity push-to-start token to the relay so incident
                    // banners can appear on the Lock Screen even when the app is closed.
                    LiveActivityPushManager.start()
                    // Cold-launch Face ID prompt when the lock is enabled.
                    appLock.unlock()
                    // Pull preferences from iCloud (no-op until iCloud KVS is enabled).
                    SettingsSync.start()
                }
                .onOpenURL { url in
                    appState.handleDeepLink(url)
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        appState.startRealtime()
                        appState.startForegroundPolling()
                        appState.consumePendingIntentLink()
                        // Re-assert push registration each time the app comes forward.
                        PushRegistrar.ensureRegistered()
                        // You're in the app now — clear the Dynamic Island/Lock-Screen
                        // incident so it gets out of your way.
                        IncidentActivityController.end()
                        // Prompt for Face ID if we locked on the way out.
                        appLock.unlock()
                    case .background:
                        appState.stopRealtime()
                        appState.stopForegroundPolling()
                        BackgroundRefreshManager.schedule()
                        // Re-lock so the app-switcher snapshot and next open are private.
                        appLock.lockIfEnabled()
                        // Push preferences up to iCloud (no-op until iCloud KVS is enabled).
                        SettingsSync.pushToCloud()
                    default:
                        break
                    }
                }
        }
    }
}
