import SwiftUI
import UIKit

/// Presents the lock / privacy cover in its own `UIWindow`, ABOVE everything the app presents.
///
/// **Why a window and not an overlay.** The covers were `.overlay` modifiers on the root view.
/// SwiftUI presents `.sheet` and `.fullScreenCover` in their own presentation context on top of
/// that view, so anything modal sat ABOVE the cover:
///
///  • the app-switcher snapshot showed live camera frames whenever a sheet was open — the exact
///    leak `PrivacyCoverView` exists to prevent;
///  • worse, the biometric lock rendered BEHIND an open sheet, leaving that sheet's content
///    visible *and interactive* to whoever picked the phone up. A lock you can reach around is
///    not a lock.
///
/// A window at `.alert + 1` is above the app's own modals. iOS renders true system permission
/// alerts out-of-process, so those still appear over this — the cover cannot trap the user behind
/// a permission prompt.
///
/// **This is purely additive.** The root-view overlays stay exactly as they were, so if this window
/// never appears for any reason, behaviour is what it is today rather than worse.
@MainActor
final class SecurityCoverWindow {
    static let shared = SecurityCoverWindow()

    private var window: UIWindow?
    /// What the window is currently showing, so an unchanged state doesn't rebuild it every time
    /// the observed state republishes.
    private var shown: Mode = .none

    enum Mode: Equatable { case none, cover, locked }

    private init() {}

    func update(mode: Mode, onUnlock: @escaping () -> Void) {
        guard mode != shown else { return }
        shown = mode

        guard mode != .none else { dismiss(); return }
        guard let scene = Self.activeScene() else { return }

        let root = UIHostingController(rootView: CoverRoot(mode: mode, onUnlock: onUnlock))
        root.view.backgroundColor = .black
        // Dark-only app; the cover must not render light chrome if the device is in light mode.
        root.overrideUserInterfaceStyle = .dark

        let w = window ?? UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.rootViewController = root
        // The lock needs touches (its unlock button). The plain cover appears only while the app is
        // inactive, so it takes no input — and staying non-interactive means it can never swallow a
        // tap during the brief inactive→active flicker of a system dialog.
        w.isUserInteractionEnabled = (mode == .locked)
        w.isHidden = false
        if mode == .locked { w.makeKey() }
        window = w
    }

    private func dismiss() {
        window?.isHidden = true
        window?.rootViewController = nil
        // Dropped rather than kept around: a retained key window at alert level is exactly the kind
        // of thing that strands touches if the app is later restored into a different scene.
        window = nil
    }

    private static func activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState != .unattached } ??
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    private struct CoverRoot: View {
        let mode: Mode
        let onUnlock: () -> Void

        var body: some View {
            switch mode {
            case .locked: LockOverlayView(onUnlock: onUnlock)
            case .cover, .none: PrivacyCoverView()
            }
        }
    }
}
