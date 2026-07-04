import SwiftUI
import AVFoundation
import CoreSpotlight

@main
struct ApexSightApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var notificationDelegate = NotificationResponseDelegate()
    @StateObject private var appLock = AppLockController()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        NativeNotificationManager.registerCategories()
        // NOTE: the audio session is intentionally NOT activated here. Activating .playback at
        // launch interrupts/ducks the user's music or podcast before any video even plays (and
        // live video defaults to muted). The clip player and live unmute take the session on
        // demand, only when there's actually audio to play.
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                // Reactive glow that traces the Dynamic Island and pulses with live camera
                // activity. Only once signed in (nothing to react to on onboarding), and it
                // sits UNDER the alert/offline banners + privacy covers so it never fights them.
                .overlay {
                    if appState.session != nil {
                        DynamicIslandAura()
                            .environmentObject(appState)
                            .allowsHitTesting(false)
                    }
                }
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
                // Privacy covers. The biometric LockOverlay (with an unlock button) appears
                // only when the optional lock is enabled and engaged. The plain PrivacyCover
                // is unconditional — it hides live camera frames from the app-switcher snapshot
                // for every user, enabled lock or not, and clears itself on `.active`.
                .overlay {
                    if appLock.isLocked {
                        LockOverlayView { appLock.unlock() }
                            .transition(.opacity)
                    } else if appLock.isObscured && appState.session != nil {
                        // Only cover once signed in — there's no camera content to protect
                        // before that, and covering would otherwise flash behind the onboarding
                        // Local Network / notification permission dialogs (which make us inactive).
                        PrivacyCoverView()
                            .transition(.opacity)
                    }
                }
                // The whole design system is a hardcoded dark-glass palette (near-white text,
                // dark surfaces). Light mode would render unreadable, so the app is dark-only —
                // pinned here rather than exposed as a broken Appearance setting.
                .preferredColorScheme(.dark)
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
                    // Register for push + (re)send the token to the relay on launch — but only
                    // once signed in, so a brand-new user isn't hit with a notifications prompt
                    // before they've even connected a server (sign-in requests it in context).
                    if appState.session != nil { PushRegistrar.ensureRegistered() }
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
                // Tap a Frigate event from iOS Spotlight → open it (identifier is the apex:// link).
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                       let url = URL(string: id) {
                        appState.handleDeepLink(url)
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // Lift the privacy cover now that real content is safe to show.
                        appLock.markRevealed()
                        appState.startRealtime()
                        appState.startForegroundPolling()
                        appState.consumePendingIntentLink()
                        // Re-assert push registration each time the app comes forward (signed in only).
                        if appState.session != nil { PushRegistrar.ensureRegistered() }
                        // You're in the app now — clear the Dynamic Island/Lock-Screen
                        // incident so it gets out of your way.
                        IncidentActivityController.end()
                        // Prompt for Face ID if we locked on the way out.
                        appLock.unlock()
                    case .inactive:
                        // Drop the opaque cover as soon as the app goes inactive (app-switcher,
                        // Control Center, incoming call) — before `.background` — so live frames
                        // never make it into the multitasking snapshot. Default users get this
                        // even without the biometric lock turned on.
                        appLock.markObscured()
                    case .background:
                        appState.stopRealtime()
                        appState.stopForegroundPolling()
                        BackgroundRefreshManager.schedule()
                        // Re-lock so the app-switcher snapshot and next open are private.
                        appLock.lockIfEnabled()
                        // Push preferences up to iCloud (no-op until iCloud KVS is enabled).
                        SettingsSync.pushToCloud()
                    @unknown default:
                        break
                    }
                }
        }
    }
}
