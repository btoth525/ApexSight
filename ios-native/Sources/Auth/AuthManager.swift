import Foundation
import Security
import WebKit
import LocalAuthentication

// MARK: - AuthManager

@MainActor
final class AuthManager: ObservableObject {
    static let shared = AuthManager()
    private init() {
        // Attempt to restore an existing token on launch
        _token = KeychainHelper.read(service: "ApexSight", account: "frigate_token")
        isAuthenticated = _token != nil
    }

    @Published var isAuthenticated: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private(set) var token: String? {
        get { _token }
        set {
            _token = newValue
            isAuthenticated = newValue != nil
        }
    }
    private var _token: String?

    // MARK: - Login

    func login(username: String, password: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let jwt = try await FrigateAPI.shared.login(username: username, password: password)
            persist(token: jwt)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Biometric unlock

    /// Returns true if a saved token exists and biometric auth succeeded.
    func authenticateWithBiometrics() async -> Bool {
        guard let _ = KeychainHelper.read(service: "ApexSight", account: "frigate_token") else {
            return false
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Authenticate to access ApexSight"
            )
            if success {
                _token = KeychainHelper.read(service: "ApexSight", account: "frigate_token")
                isAuthenticated = _token != nil
            }
            return success
        } catch {
            return false
        }
    }

    // MARK: - Logout

    func logout() {
        KeychainHelper.delete(service: "ApexSight", account: "frigate_token")
        _token = nil
        isAuthenticated = false
        clearCookies()
    }

    // MARK: - Persistence

    private func persist(token: String) {
        KeychainHelper.save(token, service: "ApexSight", account: "frigate_token")
        self.token = token
        injectCookie(token: token)
    }

    // MARK: - Cookie injection for WKWebView

    private func injectCookie(token: String) {
        guard let baseURL = URL(string: FrigateAPI.shared.baseURL),
              let host = baseURL.host else { return }

        let cookieProperties: [HTTPCookiePropertyKey: Any] = [
            .name: "frigate_token",
            .value: token,
            .domain: host,
            .path: "/",
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(60 * 60 * 24 * 30), // 30 days
        ]
        if let cookie = HTTPCookie(properties: cookieProperties) {
            WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    private func clearCookies() {
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) {}
        }
        if let cookies = HTTPCookieStorage.shared.cookies {
            cookies.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        }
    }
}

// MARK: - Keychain Helper

enum KeychainHelper {
    @discardableResult
    static func save(_ value: String, service: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        delete(service: service, account: account) // Remove old entry first

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func read(service: String, account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
