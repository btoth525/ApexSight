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
    }

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
