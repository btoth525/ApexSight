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

    /// Enter landscape-capable mode (full-screen video). Asks the system to re-evaluate so a
    /// phone already held sideways rotates into landscape immediately.
    @MainActor static func enableLandscape() {
        allowsLandscape = true
        requestGeometryUpdate(nil)   // nil = allow whatever the mask now permits (follows the device)
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
        if let orientation {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
        }
        // Nudge the top view controller to adopt the new supported set (required for the
        // portrait lock to actually take effect on dismiss).
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}
