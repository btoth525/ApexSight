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

    /// Returns the existing pairing code or generates a new one (APEX-XXXX-XXXX)
    /// using an unambiguous alphabet (no 0/O/1/I).
    @discardableResult
    static func ensurePairingCode() -> String {
        if let existing = pairingCode, !existing.isEmpty { return existing }
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        func block() -> String { String((0..<4).map { _ in alphabet.randomElement()! }) }
        let code = "APEX-\(block())-\(block())"
        pairingCode = code
        return code
    }
}
