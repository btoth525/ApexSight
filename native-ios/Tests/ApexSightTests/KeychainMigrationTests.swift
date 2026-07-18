import Testing
import Foundation
import Security
@testable import ApexSightNative

/// Exercises the REAL Keychain, not a mock — `ApexSightTests` runs hosted inside the app under
/// test, so it shares the app's actual entitlements/access groups. This specifically verifies
/// the migration KeychainStore performs when it finds an item in the pre-existing shared access
/// group (where every app-only secret used to silently land, before the app got its own private
/// group) but not yet in the new private group — the riskiest change made this session: get the
/// group strings or the fallback order wrong here and a real user is silently logged out.
@Suite("Keychain access-group migration", .serialized)
struct KeychainMigrationTests {
    // Must match KeychainStore's private constants exactly — duplicated here deliberately so
    // the test proves the ACTUAL entitlement strings resolve, rather than importing a shared
    // constant that could hide a mismatch between the two.
    private static let privateGroup = "3Q9ZUDN4QZ.com.brandontoth.apexsight.native"
    private static let legacyGroup = "3Q9ZUDN4QZ.com.brandontoth.apexsight.shared"
    private static let testKey = "com.brandontoth.apexsight.native.alarmCode"

    private func rawDelete(group: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Self.testKey,
            kSecAttrAccessGroup as String: group,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func rawAdd(group: String, value: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Self.testKey,
            kSecAttrAccessGroup as String: group,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil)
    }

    private func rawExists(group: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Self.testKey,
            kSecAttrAccessGroup as String: group,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    /// Both access groups actually resolve for this app — if either string were wrong (a typo,
    /// or the entitlement never landed), every add below would fail with errSecMissingEntitlement
    /// and this would catch that BEFORE the migration-logic tests below could give a false pass.
    @Test("Both access groups are actually usable by this app")
    func accessGroupsAreEntitled() {
        rawDelete(group: Self.privateGroup)
        rawDelete(group: Self.legacyGroup)
        let privateStatus = rawAdd(group: Self.privateGroup, value: "probe")
        let legacyStatus = rawAdd(group: Self.legacyGroup, value: "probe")
        rawDelete(group: Self.privateGroup)
        rawDelete(group: Self.legacyGroup)
        #expect(privateStatus == errSecSuccess)
        #expect(legacyStatus == errSecSuccess)
    }

    @Test("An item that only exists in the legacy shared group is found, migrated, and scrubbed")
    func migratesFromLegacyGroup() {
        rawDelete(group: Self.privateGroup)
        rawDelete(group: Self.legacyGroup)

        // Simulate a pre-upgrade install: the alarm code already exists, but only in the OLD
        // (shared) group — exactly what every real installed device has right now.
        #expect(rawAdd(group: Self.legacyGroup, value: "5251") == errSecSuccess)
        #expect(!rawExists(group: Self.privateGroup))

        let store = KeychainStore()
        #expect(store.alarmCode == "5251")           // found via the legacy fallback
        #expect(rawExists(group: Self.privateGroup))  // migrated into the private group...
        #expect(!rawExists(group: Self.legacyGroup))  // ...and scrubbed from the old one

        // A second read must not need the fallback anymore — it's now in the private group.
        #expect(store.alarmCode == "5251")

        store.clearAlarmCode()
        rawDelete(group: Self.privateGroup)
        rawDelete(group: Self.legacyGroup)
    }

    @Test("A fresh save lands directly in the private group, never the legacy one")
    func freshSaveUsesPrivateGroupOnly() {
        rawDelete(group: Self.privateGroup)
        rawDelete(group: Self.legacyGroup)

        let store = KeychainStore()
        #expect(store.saveAlarmCode("9999"))
        #expect(rawExists(group: Self.privateGroup))
        #expect(!rawExists(group: Self.legacyGroup))
        #expect(store.alarmCode == "9999")

        store.clearAlarmCode()
        #expect(!rawExists(group: Self.privateGroup))
        rawDelete(group: Self.privateGroup)
        rawDelete(group: Self.legacyGroup)
    }

    @Test("No item in either group fails open to nil, not a crash")
    func missingItemReturnsNil() {
        rawDelete(group: Self.privateGroup)
        rawDelete(group: Self.legacyGroup)
        #expect(KeychainStore().alarmCode == nil)
    }
}

/// DeviceTokenStore.pairingCode used to live in a plaintext app-group plist (the account's
/// private ingest token, once signed in, is just as sensitive as the alarm code — it grants
/// disarm/doorbell-talk/mode-change access). Verifies the same migrate-and-scrub pattern
/// `accountToken` already used is applied correctly here too, against the real Keychain/UserDefaults.
@Suite("Pairing code plist-to-Keychain migration", .serialized)
struct PairingCodeMigrationTests {
    private static let plistKey = "apex.pairingCode"
    private static let keychainAccountKey = "com.brandontoth.apexsight.native.pairingCode"
    private static let privateGroup = "3Q9ZUDN4QZ.com.brandontoth.apexsight.native"

    private var defaults: UserDefaults? { UserDefaults(suiteName: ApexAppGroup.identifier) }

    private func rawKeychainDelete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Self.keychainAccountKey,
            kSecAttrAccessGroup as String: Self.privateGroup,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func reset() {
        defaults?.removeObject(forKey: Self.plistKey)
        rawKeychainDelete()
    }

    @Test("A legacy plaintext plist value is migrated into the Keychain and scrubbed")
    func migratesFromPlist() {
        reset()
        defaults?.set("APEX-TEST-9999", forKey: Self.plistKey)

        #expect(DeviceTokenStore.pairingCode == "APEX-TEST-9999")
        #expect(defaults?.string(forKey: Self.plistKey) == nil)  // scrubbed
        #expect(DeviceTokenStore.pairingCode == "APEX-TEST-9999")  // now served from the Keychain

        reset()
    }

    @Test("Setting a new value never leaves a plaintext plist copy")
    func freshSetNeverHitsPlist() {
        reset()
        DeviceTokenStore.pairingCode = "APEX-TEST-8888"
        #expect(defaults?.string(forKey: Self.plistKey) == nil)
        #expect(DeviceTokenStore.pairingCode == "APEX-TEST-8888")
        reset()
    }

    @Test("Clearing removes it from both the Keychain and any stale plist copy")
    func clearingRemovesEverywhere() {
        reset()
        DeviceTokenStore.pairingCode = "APEX-TEST-7777"
        DeviceTokenStore.pairingCode = nil
        #expect(DeviceTokenStore.pairingCode == nil)
        reset()
    }
}
