import Foundation
import Security

/// The Frigate bearer token, stored in a **shared Keychain access group** so the app, the
/// notification-service extension, and the widgets can all read it without copying the secret
/// into plaintext App-Group `UserDefaults` (which is an unencrypted plist on disk).
///
/// Only the token lives here — the base URL is not a secret and stays in App-Group defaults.
/// Readers (NSE / widgets) treat a miss as "no token" and fall back to their existing
/// placeholder behaviour, so a misconfiguration degrades to a missing image, never a crash.
public enum SharedTokenStore {
    /// Must match the `keychain-access-groups` entitlement on every target that links this file:
    /// `$(AppIdentifierPrefix)com.brandontoth.apexsight.shared`. `$(AppIdentifierPrefix)` expands
    /// to the team id + ".", so the runtime group string is the team-prefixed value below.
    private static let accessGroup = "3Q9ZUDN4QZ.com.brandontoth.apexsight.shared"
    private static let account = "apex.frigateToken"

    /// Store (or replace) the token. Returns whether it actually landed in the Keychain.
    @discardableResult
    public static func save(_ token: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            // Available to the extension/widget while the device is unlocked-since-boot, on this
            // device only (never synced/backed up to another device).
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        // Unexpected error: clean replace so we still end up persisted.
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Read the token, or nil if none is stored / the read fails.
    public static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Remove the token (sign-out).
    public static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup
        ]
        SecItemDelete(query as CFDictionary)
    }
}
