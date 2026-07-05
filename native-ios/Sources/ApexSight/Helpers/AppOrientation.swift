import UIKit

/// App-wide orientation policy. The app is a portrait experience everywhere (the wall, tabs, and
/// detail screens are designed for it — and iPhone "Plus/Max" models get a REGULAR size class in
/// landscape, which would reflow the whole UI into an ugly iPad-style split layout). The ONLY
/// place landscape is allowed is the full-screen video viewer, where a rotated phone should fill
/// the screen with video. The full-screen viewer flips `allowsLandscape` on appear/disappear.
enum AppOrientation {
    /// Read by `AppDelegate.application(_:supportedInterfaceOrientationsFor:)`.
    nonisolated(unsafe) static var allowsLandscape = false

    static var mask: UIInterfaceOrientationMask {
        allowsLandscape ? [.portrait, .landscapeLeft, .landscapeRight] : .portrait
    }

    /// Enter landscape-capable mode (full-screen video). If the phone is ALREADY held sideways,
    /// rotate to match it immediately; otherwise just allow landscape so a later turn rotates.
    @MainActor static func enableLandscape() {
        allowsLandscape = true
        // Match the device if it's already sideways — so opening full-screen on a phone held
        // sideways lands directly in landscape instead of needing a re-turn.
        switch UIDevice.current.orientation {
        case .landscapeLeft:  requestGeometryUpdate(.landscapeRight)   // device⇄interface are inverted
        case .landscapeRight: requestGeometryUpdate(.landscapeLeft)
        default:              requestGeometryUpdate(nil)               // portrait/flat → follow the device
        }
    }

    /// Leave landscape mode and force back to portrait (full-screen viewer closing).
    @MainActor static func lockPortrait() {
        allowsLandscape = false
        requestGeometryUpdate(.portrait)
    }

    @MainActor private static func requestGeometryUpdate(_ orientation: UIInterfaceOrientationMask?) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        // Update the supported set FIRST so the geometry request isn't rejected against a
        // stale mask, then request the target orientation.
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if let orientation {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { _ in }
        }
    }
}
