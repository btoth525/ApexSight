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
