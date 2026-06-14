import Foundation
import Security

final class KeychainStore {
    private let key = "com.brandontoth.apexsight.native.session"
    private let allSessionsKey = "com.brandontoth.apexsight.native.sessions"

    func save(session: FrigateSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        keychainSet(key: key, data: data)

        var all = loadAllSessions()
        all.removeAll { $0.baseURL == session.baseURL }
        all.append(session)
        if let allData = try? JSONEncoder().encode(all) {
            keychainSet(key: allSessionsKey, data: allData)
        }
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

    private func keychainSet(key: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        SecItemAdd(add as CFDictionary, nil)
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
