import Foundation

/// Persists the APNs device token, registration state, and the user's push-relay
/// pairing details. Stored in the app group so the token survives relaunches and
/// is shared with the notification service extension.
enum DeviceTokenStore {
    private static let tokenKey = "apex.apnsDeviceToken"
    private static let errorKey = "apex.apnsLastError"
    private static let enabledKey = "apex.pushEnabled"
    private static let relayKey = "apex.relayURL"
    private static let pairingKey = "apex.pairingCode"
    private static let pairingOverriddenKey = "apex.pairingOverridden"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: ApexAppGroup.identifier)
    }

    static var deviceTokenHex: String? {
        get { defaults?.string(forKey: tokenKey) }
        set { defaults?.set(newValue, forKey: tokenKey) }
    }

    static var lastError: String? {
        get { defaults?.string(forKey: errorKey) }
        set { defaults?.set(newValue, forKey: errorKey) }
    }

    static var pushEnabled: Bool {
        get { defaults?.bool(forKey: enabledKey) ?? false }
        set { defaults?.set(newValue, forKey: enabledKey) }
    }

    /// Base URL of the user's push relay, e.g. https://push.yourdomain.com.
    /// Defaults to the app's baked-in relay (RelayConfig.defaultURL) when unset.
    static var relayURL: String {
        get {
            let stored = defaults?.string(forKey: relayKey)?.trimmingCharacters(in: .whitespaces)
            if let stored, !stored.isEmpty { return stored }
            return RelayConfig.defaultURL
        }
        set { defaults?.set(newValue.trimmingCharacters(in: .whitespaces), forKey: relayKey) }
    }

    /// The household pairing code shared with the Home Assistant bridge addon.
    static var pairingCode: String? {
        get { defaults?.string(forKey: pairingKey) }
        set { defaults?.set(newValue, forKey: pairingKey) }
    }

    /// True once the user explicitly picked a code via "Join household" — then we
    /// stop overriding it with the baked shared default.
    static var pairingOverridden: Bool {
        get { defaults?.bool(forKey: pairingOverriddenKey) ?? false }
        set { defaults?.set(newValue, forKey: pairingOverriddenKey) }
    }

    /// Resolves the pairing code to use:
    ///   1. an explicit user override ("Join household"),
    ///   2. else the baked shared household code (RelayConfig.defaultPairingCode),
    ///   3. else a stored per-device code,
    ///   4. else a freshly generated one (APEX-XXXX-XXXX, unambiguous alphabet).
    @discardableResult
    static func ensurePairingCode() -> String {
        if pairingOverridden, let existing = pairingCode, !existing.isEmpty { return existing }

        let shared = RelayConfig.defaultPairingCode
        if !shared.isEmpty {
            if pairingCode != shared { pairingCode = shared }
            return shared
        }

        if let existing = pairingCode, !existing.isEmpty { return existing }
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        func block() -> String { String((0..<4).map { _ in alphabet.randomElement()! }) }
        let code = "APEX-\(block())-\(block())"
        pairingCode = code
        return code
    }
}
