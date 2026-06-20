import Foundation

/// Talks to the relay's account API (/v1/auth/*). On success the caller stores the
/// returned session token + the account's private `ingest_token` (which becomes the
/// push pairing code) via `DeviceTokenStore.applyAccount`.
enum AccountClient {
    struct Session: Decodable {
        let token: String
        let ingest_token: String
        let email: String?
    }

    struct AuthError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The Frigate connection stored on the account, fetched after sign-in so the app
    /// connects with no manual setup.
    struct FrigateProfile: Decodable {
        let url: String?
        let username: String?
        let password: String?
        var isConfigured: Bool { (url?.isEmpty == false) }
    }

    static func signup(relayURL: String, email: String, password: String) async throws -> Session {
        try await post(relayURL, "/v1/auth/signup", ["email": email, "password": password])
    }

    static func login(relayURL: String, email: String, password: String) async throws -> Session {
        try await post(relayURL, "/v1/auth/login", ["email": email, "password": password])
    }

    static func apple(relayURL: String, identityToken: String, email: String?) async throws -> Session {
        var body: [String: String] = ["identity_token": identityToken]
        if let email, !email.isEmpty { body["email"] = email }
        return try await post(relayURL, "/v1/auth/apple", body)
    }

    /// Pulls the Frigate connection saved on the account so the app can sign in by itself.
    static func fetchFrigate(relayURL: String, token: String) async throws -> FrigateProfile {
        let (data, code) = try await request("GET", relayURL, "/v1/frigate", token: token, body: nil)
        guard (200..<300).contains(code) else {
            throw AuthError(message: detail(from: data) ?? "Couldn't load your server (\(code)).")
        }
        return try JSONDecoder().decode(FrigateProfile.self, from: data)
    }

    /// Saves the Frigate connection to the account (so other devices auto-connect too).
    /// Leave `password` empty to keep the stored one.
    static func saveFrigate(relayURL: String, token: String, url: String, username: String, password: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["url": url, "username": username, "password": password])
        let (data, code) = try await request("PUT", relayURL, "/v1/frigate", token: token, body: body)
        guard (200..<300).contains(code) else {
            throw AuthError(message: detail(from: data) ?? "Couldn't save your server (\(code)).")
        }
    }

    /// Permanently deletes the account and everything routed to it (devices, settings,
    /// stored Frigate connection). Required for in-app account deletion.
    static func deleteAccount(relayURL: String, token: String) async throws {
        let (data, code) = try await request("DELETE", relayURL, "/v1/auth/me", token: token, body: nil)
        guard (200..<300).contains(code) else {
            throw AuthError(message: detail(from: data) ?? "Couldn't delete your account (\(code)).")
        }
    }

    private static func post(_ relayURL: String, _ path: String, _ body: [String: String]) async throws -> Session {
        var trimmed = relayURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + path) else {
            throw AuthError(message: "The relay URL isn't valid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw AuthError(message: detail(from: data) ?? "Something went wrong (\(code)). Please try again.")
        }
        return try JSONDecoder().decode(Session.self, from: data)
    }

    /// Authenticated request to the relay (Bearer session token). Returns (data, status).
    private static func request(_ method: String, _ relayURL: String, _ path: String,
                                token: String, body: Data?) async throws -> (Data, Int) {
        var trimmed = relayURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + path) else {
            throw AuthError(message: "The relay URL isn't valid.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// FastAPI returns errors as {"detail": "..."} — surface that to the user.
    private static func detail(from data: Data) -> String? {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let detail = obj["detail"] as? String,
            !detail.isEmpty
        else { return nil }
        return detail
    }
}
