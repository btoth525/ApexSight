import Foundation
import Security

/// Every secret here (disarm code, account bearer token, Frigate session incl. password) is
/// APP-ONLY — no NSE/widget code reads any of it. Before this file was updated, none of its
/// queries specified `kSecAttrAccessGroup`, and the app's entitlements declared only ONE
/// keychain-access-group (the one ALSO shared with the NSE/widgets for `SharedTokenStore`'s
/// Frigate token) — so every item here silently landed in that SHARED group, readable by the
/// notification extension and widgets despite the comments below claiming otherwise. The app
/// target's entitlements now also declare a second, PRIVATE group
/// (`$(AppIdentifierPrefix)com.brandontoth.apexsight.native`), and every query here is explicit
/// about using it. Existing installs already have items physically tagged with the old shared
/// group, so `keychainGet` falls back to it once and migrates-and-scrubs on find — the exact
/// pattern `DeviceTokenStore.accountToken` already uses for its plist→Keychain migration.
final class KeychainStore {
    private let key = "com.brandontoth.apexsight.native.session"
    private let allSessionsKey = "com.brandontoth.apexsight.native.sessions"

    /// This app target's own Keychain access group — nothing outside the main app can read it.
    private let accessGroup = "3Q9ZUDN4QZ.com.brandontoth.apexsight.native"
    /// Where every item here used to live (implicitly, before this file specified an access
    /// group) — the group the NSE/widgets also hold. Read-only: only ever consulted as a
    /// migration fallback, never written to going forward.
    private let legacyAccessGroup = "3Q9ZUDN4QZ.com.brandontoth.apexsight.shared"

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

    // MARK: - Alarm (Alarmo) disarm code

    private var alarmCodeKey: String { "com.brandontoth.apexsight.native.alarmCode" }

    /// The Alarmo code used to disarm the house from the app. Stored in the Keychain (not the app
    /// group / UserDefaults) because it's a security credential; the app only sends it after Face ID.
    @discardableResult
    func saveAlarmCode(_ code: String) -> Bool {
        // The disarm code is read only interactively (after Face ID, app in foreground) — never by
        // the NSE/widgets in the background — so it takes the tightest accessibility: readable only
        // while the device is unlocked, on this device only. (The session token below stays on
        // AfterFirstUnlock because the notification extension reads it while the phone is locked.)
        keychainSet(key: alarmCodeKey, data: Data(code.utf8),
                    accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    }

    var alarmCode: String? {
        // Migrate at the SAME tight accessibility saveAlarmCode uses — a plain fallback to the
        // (looser) default would briefly weaken this one credential's policy after migration.
        keychainGet(key: alarmCodeKey, migrateAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    func clearAlarmCode() { keychainDelete(key: alarmCodeKey) }

    // MARK: - ApexSight account bearer token

    private var accountTokenKey: String { "com.brandontoth.apexsight.native.accountToken" }

    /// The signed-in ApexSight account's bearer session token. A per-user secret, so it lives in the
    /// Keychain rather than the app-group plist. App-target only (no access group) — no extension
    /// reads it.
    @discardableResult
    func saveAccountToken(_ token: String) -> Bool {
        keychainSet(key: accountTokenKey, data: Data(token.utf8))
    }

    var accountToken: String? {
        keychainGet(key: accountTokenKey).flatMap { String(data: $0, encoding: .utf8) }
    }

    func clearAccountToken() { keychainDelete(key: accountTokenKey) }

    // MARK: - Household pairing code / account ingest token

    private var pairingCodeKey: String { "com.brandontoth.apexsight.native.pairingCode" }

    /// The household pairing code — or, once signed into an account, that account's private
    /// ingest token, which routes push through it exactly like the pairing code (see
    /// `DeviceTokenStore.applyAccount`). Either way it's a per-user/household secret that grants
    /// disarm/doorbell-talk/mode-change access, so it lives in the Keychain, not the app-group
    /// plist. No extension reads it.
    @discardableResult
    func savePairingCode(_ code: String) -> Bool {
        keychainSet(key: pairingCodeKey, data: Data(code.utf8))
    }

    var pairingCode: String? {
        keychainGet(key: pairingCodeKey).flatMap { String(data: $0, encoding: .utf8) }
    }

    func clearPairingCode() { keychainDelete(key: pairingCodeKey) }

    /// Writes a value, updating an existing item in place rather than delete-then-add.
    /// This both checks the result (the old code ignored `SecItemAdd`'s status, so a
    /// failed write silently logged the user out on next launch) and closes the brief
    /// delete-before-add window where a concurrent read could see no item. Returns
    /// whether the value is now stored. Always writes to this app's PRIVATE access group.
    @discardableResult
    private func keychainSet(key: String, data: Data,
                             accessible: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        if updateStatus == errSecItemNotFound {
            var add = query
            add[kSecAttrAccessible as String] = accessible
            add[kSecValueData as String] = data
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }

        // Unexpected error (e.g. a stale item with mismatched attributes): fall back to
        // a clean replace so we still end up persisted rather than silently failing.
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecAttrAccessible as String] = accessible
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Reads from this app's private group; falls back to the legacy shared-group location
    /// ONLY if the private group has nothing, and migrates-and-scrubs on a hit so the item never
    /// lives in both places and future reads skip the fallback. `migrateAccessible` is the
    /// accessibility class the migrated copy is written with — pass whatever this key's own
    /// save function uses (see `alarmCode`) so migration can't silently loosen a tighter policy.
    private func keychainGet(
        key: String, migrateAccessible: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) -> Data? {
        if let data = keychainGet(key: key, group: accessGroup) { return data }
        guard let legacy = keychainGet(key: key, group: legacyAccessGroup) else { return nil }
        if keychainSet(key: key, data: legacy, accessible: migrateAccessible) {
            keychainDelete(key: key, group: legacyAccessGroup)
        }
        return legacy
    }

    private func keychainGet(key: String, group: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: group,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Deletes from this app's private group (the only group this class ever writes to going
    /// forward). `group` lets the migration path scrub the legacy shared-group copy specifically.
    private func keychainDelete(key: String, group: String? = nil) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: group ?? accessGroup
        ]
        SecItemDelete(query as CFDictionary)
    }
}
