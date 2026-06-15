import Foundation

/// Talks to the ApexSight push relay's public API. Registers this device's APNs
/// token under the household pairing code so the relay knows where to deliver
/// pushes forwarded by the Home Assistant bridge.
enum RelayClient {
    enum RelayError: LocalizedError {
        case invalidURL
        case server(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Enter a valid relay URL (https://…)."
            case let .server(code, msg): return "Relay error \(code): \(msg)"
            }
        }
    }

    private struct RegisterBody: Encodable {
        let device_token: String
        let pairing_code: String
        let environment: String
        let platform: String
    }

    private struct UnregisterBody: Encodable {
        let device_token: String
    }

    /// Result of a `/healthz` probe used for the green/red status dot.
    struct Health: Decodable {
        let ok: Bool
        let apns_configured: Bool?
    }

    /// Returns the relay's health, or nil if it's unreachable.
    static func health(relayURL: String) async -> Health? {
        var trimmed = relayURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + "/healthz") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            guard ok else { return nil }
            return try? JSONDecoder().decode(Health.self, from: data)
        } catch {
            return nil
        }
    }

    static func register(relayURL: String, deviceToken: String, pairingCode: String, environment: String) async throws {
        let body = RegisterBody(
            device_token: deviceToken,
            pairing_code: pairingCode,
            environment: environment,
            platform: "ios"
        )
        try await post(relayURL: relayURL, path: "/v1/register", body: body)
    }

    static func unregister(relayURL: String, deviceToken: String) async throws {
        try await post(relayURL: relayURL, path: "/v1/unregister", body: UnregisterBody(device_token: deviceToken))
    }

    private static func post<T: Encodable>(relayURL: String, path: String, body: T) async throws {
        var trimmed = relayURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let base = URL(string: trimmed), base.scheme != nil, base.host != nil,
              let url = URL(string: trimmed + path) else { throw RelayError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw RelayError.server(code, msg)
        }
    }
}
