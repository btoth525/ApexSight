import Foundation

/// Persists the APNs device token and registration state for the optional push
/// companion. Stored in the app group so the token survives relaunches and can be
/// surfaced (copyable) in Settings for the user to paste into their companion config.
enum DeviceTokenStore {
    private static let tokenKey = "apex.apnsDeviceToken"
    private static let errorKey = "apex.apnsLastError"
    private static let enabledKey = "apex.pushEnabled"

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
}
