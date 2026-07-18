import Foundation
import LocalAuthentication
import SwiftUI

/// Thin wrapper over LocalAuthentication for the optional app lock. Uses
/// `.deviceOwnerAuthentication`, so Face ID / Touch ID fall back to the device
/// passcode automatically — the user can never get permanently locked out.
enum BiometricLock {
    /// True when the device can authenticate at all (biometry enrolled or a passcode set).
    /// If this is false we must NOT lock, or the user would be stranded with no way in.
    static var isAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Human label for the available biometry, for the settings toggle and lock screen.
    static var label: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    static var symbolName: String {
        switch LAContext().biometryType {
        case .faceID, .opticID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock.fill"
        }
    }

    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return false }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}

/// Drives the optional Face ID lock overlay. Locks when the app backgrounds (so the
/// app-switcher preview and a reopened app are private) and unlocks via biometrics/passcode.
@MainActor
final class AppLockController: ObservableObject {
    /// Persisted user preference (also the key the Settings toggle binds to).
    static let preferenceKey = "biometricLockEnabled"

    @Published private(set) var isLocked = false
    /// True whenever the app is not active (inactive/background). Drives an unconditional
    /// opaque privacy cover so live camera frames never leak into the app-switcher snapshot,
    /// regardless of whether the optional biometric lock is enabled.
    @Published private(set) var isObscured = false
    private var authenticating = false

    private var enabled: Bool { UserDefaults.standard.bool(forKey: Self.preferenceKey) }

    init() {
        // Start locked on cold launch when enabled, so content never flashes before the
        // cover appears (the cover triggers the unlock prompt as soon as it renders).
        isLocked = enabled && BiometricLock.isAvailable
    }

    /// Lock the app if the user enabled it AND the device actually has a way to unlock.
    /// The availability guard prevents a lockout on a device with no passcode/biometry.
    func lockIfEnabled() {
        guard enabled, BiometricLock.isAvailable else { isLocked = false; return }
        isLocked = true
        // A user who turned on the biometric lock wants privacy while backgrounded — without
        // this, a system Picture-in-Picture window could keep floating live camera video over
        // the home screen with zero authentication, even while this lock screen shows inside
        // the app itself. Scoped to here (not every backgrounding) since PiP surviving the
        // background is a deliberate feature for users who never opted into the lock.
        LivePiPController.current?.stop()
    }

    /// Drop the opaque privacy cover the moment the app is no longer active. Called on
    /// `.inactive` (before `.background`) so live content can't flash during the transition.
    func markObscured() { isObscured = true }

    /// Lift the privacy cover once the app is active again (and the biometric lock, if any,
    /// has been cleared by `unlock()`).
    func markRevealed() { isObscured = false }

    /// Prompt for biometrics to clear the lock. Idempotent — ignores re-entry while a
    /// prompt is already on screen.
    func unlock() {
        guard isLocked, !authenticating else { return }
        guard BiometricLock.isAvailable else { isLocked = false; return }
        authenticating = true
        Task { [weak self] in
            let ok = await BiometricLock.authenticate(reason: "Unlock ApexSight to view your cameras")
            self?.authenticating = false
            if ok { self?.isLocked = false }
        }
    }
}
