import Foundation
import Security

final class KeychainStore {
    private let key = "com.brandontoth.apexsight.native.session"
    private let allSessionsKey = "com.brandontoth.apexsight.native.sessions"

    /// Persists the active session (and the multi-server list). Returns whether the
    /// active-session write actually landed in the Keychain, so callers can tell the
    /// difference between "signed in" and "signed in but won't survive a relaunch".
    @discardableResult
    func save(session: FrigateSession) -> Bool {
        guard let data = try? JSONEncoder().encode(session) else { return false }
        let ok = keychainSet(key: key, data: data)

        var all = loadAllSessions()
        all.removeAll { $0.baseURL == session.baseURL }
        all.append(session)
        if let allData = try? JSONEncoder().encode(all) {
            keychainSet(key: allSessionsKey, data: allData)
        }
        return ok
    }

    func loadSession() -> FrigateSession? {
        guard let data = keychainGet(key: key) else { return nil }
        return try? JSONDecoder().decode(FrigateSession.self, from: data)
    }

    func loadAllSessions() -> [FrigateSession] {
        guard let data = keychainGet(key: allSessionsKey) else { return [] }
        return (try? JSONDecoder().decode([FrigateSession].self, from: data)) ?? []
    }

    func remove(session: FrigateSession) {
        var all = loadAllSessions()
        all.removeAll { $0.baseURL == session.baseURL }
        if let data = try? JSONEncoder().encode(all) {
            keychainSet(key: allSessionsKey, data: data)
        }
        if loadSession()?.baseURL == session.baseURL {
            clear()
        }
    }

    func clear() {
        keychainDelete(key: key)
        keychainDelete(key: allSessionsKey)
    }

    /// Writes a value, updating an existing item in place rather than delete-then-add.
    /// This both checks the result (the old code ignored `SecItemAdd`'s status, so a
    /// failed write silently logged the user out on next launch) and closes the brief
    /// delete-before-add window where a concurrent read could see no item. Returns
    /// whether the value is now stored.
    @discardableResult
    private func keychainSet(key: String, data: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        if updateStatus == errSecItemNotFound {
            var add = query
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecValueData as String] = data
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }

        // Unexpected error (e.g. a stale item with mismatched attributes): fall back to
        // a clean replace so we still end up persisted rather than silently failing.
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private func keychainGet(key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func keychainDelete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
