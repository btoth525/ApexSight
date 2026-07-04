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
    private static let accountTokenKey = "apex.accountToken"
    private static let accountEmailKey = "apex.accountEmail"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: ApexAppGroup.identifier)
    }

    static var deviceTokenHex: String? {
        get { defaults?.string(forKey: tokenKey) }
        set { defaults?.set(newValue, forKey: tokenKey) }
    }

    private static let relayConfirmedKey = "apex.relayRegistrationConfirmed"
    private static let relayConfirmedSeededKey = "apex.relayConfirmedSeeded"

    /// True once the relay has ACKNOWLEDGED our current registration this install.
    /// Set on a successful `RelayClient.register`, cleared when one fails.
    ///
    /// MIGRATION SEED: installs upgraded from before this flag existed already hold a
    /// token the relay ACKed under the old flow — and the relay keeps pushing to it. If
    /// the flag started false, every alert would arrive TWICE (relay push + the local
    /// fallback fired by background refresh) until the user's first app-open re-registers
    /// — a window of hours to days. So the first read on an install that already has a
    /// token seeds true, once; a genuinely failing register still clears it afterwards.
    static var relayConfirmed: Bool {
        get {
            guard let defaults else { return false }
            if !defaults.bool(forKey: relayConfirmedSeededKey) {
                defaults.set(true, forKey: relayConfirmedSeededKey)
                if deviceTokenHex?.isEmpty == false {
                    defaults.set(true, forKey: relayConfirmedKey)
                }
            }
            return defaults.bool(forKey: relayConfirmedKey)
        }
        set { defaults?.set(newValue, forKey: relayConfirmedKey) }
    }

    /// True once instant push via the relay is ACTUALLY set up — an APNs token exists
    /// AND the relay confirmed it received it. When true the app skips its own local
    /// notifications so the relay is the single source and nothing doubles up.
    /// Requiring the relay confirmation matters: an APNs token almost always arrives
    /// (Apple's side is reliable), but if the relay registration fails the relay never
    /// pushes — gating only on the token silently killed every notification path at once.
    static var hasRemotePush: Bool {
        (deviceTokenHex?.isEmpty == false) && relayConfirmed
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

    // MARK: - ApexSight account (session token + the account's private ingest token)

    /// Bearer session token for the signed-in ApexSight account, or nil.
    static var accountToken: String? {
        get { defaults?.string(forKey: accountTokenKey) }
        set { defaults?.set(newValue, forKey: accountTokenKey) }
    }

    static var accountEmail: String? {
        get { defaults?.string(forKey: accountEmailKey) }
        set { defaults?.set(newValue, forKey: accountEmailKey) }
    }

    static var isSignedInToAccount: Bool { accountToken?.isEmpty == false }

    /// Store a successful sign-in and route push through the account's private ingest
    /// token (used everywhere the pairing code was).
    static func applyAccount(token: String, ingestToken: String, email: String?) {
        accountToken = token
        accountEmail = email
        pairingCode = ingestToken
        pairingOverridden = true
    }

    /// Sign out: clear the account + stop routing push to its token.
    static func signOutAccount() {
        accountToken = nil
        accountEmail = nil
        pairingCode = nil
        pairingOverridden = false
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
        func block() -> String { String((0..<4).map { _ in alphabet.randomElement() ?? "A" }) }
        let code = "APEX-\(block())-\(block())"
        pairingCode = code
        return code
    }
}
