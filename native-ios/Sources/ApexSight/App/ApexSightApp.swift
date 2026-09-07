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

    /// Single source of truth for what the cover window shows — deliberately the SAME conditions
    /// the root-view overlays use, so the two can never disagree about whether content is covered.
    private var securityCoverMode: SecurityCoverWindow.Mode {
        if appLock.isLocked { return .locked }
        if appLock.isObscured && appState.session != nil { return .cover }
        return .none
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
                // Hide everything under the privacy cover from VoiceOver too. The cover is opaque to
                // the eye, but VoiceOver reads the view tree, not pixels — without this a VoiceOver
                // user could swipe *behind* the lock to camera names and events, defeating the lock.
                .accessibilityHidden(appLock.isLocked || (appLock.isObscured && appState.session != nil))
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
                // The overlays above only cover the root view — SwiftUI presents sheets and
                // fullScreenCovers ON TOP of them, so with any sheet open the app-switcher snapshot
                // still showed live frames and the biometric lock rendered BEHIND the sheet, whose
                // content stayed visible and interactive. This mirrors the same state into a window
                // above the modal layer. Additive: the overlays stay, so the worst case is today's
                // behaviour.
                .onChange(of: securityCoverMode) { _, mode in
                    SecurityCoverWindow.shared.update(mode: mode) { appLock.unlock() }
                }
                .onAppear {
                    SecurityCoverWindow.shared.update(mode: securityCoverMode) { appLock.unlock() }
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
                    // A launch breadcrumb, so the log can PROVE it is alive. Without it an empty
                    // log is ambiguous — "nothing went wrong" and "this build never reported" look
                    // identical, which is exactly the question you ask first when reading it.
                    // It also stamps which build produced the lines below it.
                    DiagnosticLog.shared.info(
                        "launch",
                        "app launched · build \(DiagnosticLog.buildLabel) · "
                        + (appState.session == nil ? "signed out" : "signed in"))
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
                        // Re-check the home-network fast path on every foreground — you may have
                        // walked in or out the door while the app was away.
                        appState.scheduleLocalProbe()
                        appState.consumePendingIntentLink()
                        // Anything the app recorded while it was away (including from a previous
                        // launch that was killed) goes out as soon as there's network again.
                        Task { await DiagnosticLog.shared.flush() }
                        // Re-assert push registration each time the app comes forward (signed in only).
                        if appState.session != nil {
                            PushRegistrar.ensureRegistered()
                            // Re-send the cached VoIP token too, so the doorbell self-heals if its
                            // relay registration failed at launch or the relay's device table was reset.
                            DoorbellCallManager.shared.reregisterVoIP()
                        }
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
                        // Drop any ring-warm consumer — nothing should stream while backgrounded.
                        StreamPrewarmer.shared.stopAll()
                        appState.stopForegroundPolling()
                        BackgroundRefreshManager.schedule()
                        // Re-lock so the app-switcher snapshot and next open are private.
                        appLock.lockIfEnabled()
                        // Push preferences up to iCloud (no-op until iCloud KVS is enabled).
                        SettingsSync.pushToCloud()
                        // Ship the session's log now. Backgrounding is when a testing session
                        // actually ends, and the 60s timer may never fire again before the app is
                        // killed — fire-and-forget, so it cannot delay going to background.
                        Task { await DiagnosticLog.shared.flush() }
                    @unknown default:
                        break
                    }
                }
        }
    }
}
