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

    private struct TestBody: Encodable {
        let device_token: String
        let environment: String
    }

    private struct StyleBody: Encodable {
        let pairing_code: String
        let style: NotificationStyle
    }

    private struct AICamerasBody: Encodable {
        let pairing_code: String
        let disabled: [String]
    }

    private struct GateBody: Encodable {
        let pairing_code: String
        let disarmed: Bool
        let snoozed_until: Double   // epoch seconds; 0 = not snoozed
    }

    private struct RecapBody: Encodable {
        let pairing_code: String
        let enabled: Bool
        let hour: Int
        let minute: Int
        let tz_offset: Int
    }

    private struct ActivityBody: Encodable {
        let pairing_code: String
        let token: String
        let environment: String
        let kind: String   // "start" = push-to-start token
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

    /// Tell the relay which cameras have AI descriptions in notifications turned OFF, so the
    /// HomeKit-style GenAI-description follow-up is only sent for the cameras the user enabled.
    static func syncAICameras(relayURL: String, pairingCode: String, disabled: [String]) async throws {
        try await post(relayURL: relayURL, path: "/v1/ai-cameras",
                       body: AICamerasBody(pairing_code: pairingCode, disabled: disabled))
    }

    /// Asks the relay to send a test push to this device.
    static func sendTest(relayURL: String, deviceToken: String, environment: String) async throws {
        try await post(relayURL: relayURL, path: "/v1/test", body: TestBody(device_token: deviceToken, environment: environment))
    }

    /// Saves this household's notification style on the relay, so app-closed pushes
    /// are rendered the way the user configured in the app.
    static func syncStyle(relayURL: String, pairingCode: String, style: NotificationStyle) async throws {
        try await post(relayURL: relayURL, path: "/v1/style", body: StyleBody(pairing_code: pairingCode, style: style))
    }

    /// Tells the relay the household's current arm/snooze state so app-closed pushes
    /// are suppressed while disarmed or snoozed — keeping the relay consistent with
    /// the in-app delivery gate.
    static func syncGate(relayURL: String, pairingCode: String, disarmed: Bool, snoozedUntil: Double) async throws {
        try await post(relayURL: relayURL, path: "/v1/gate",
                       body: GateBody(pairing_code: pairingCode, disarmed: disarmed, snoozed_until: snoozedUntil))
    }

    /// Saves the Daily Recap schedule on the relay so the summary is delivered at the
    /// chosen local time even when the app is fully closed. `tzOffset` is seconds from GMT.
    static func syncRecap(relayURL: String, pairingCode: String, enabled: Bool, hour: Int, minute: Int, tzOffset: Int) async throws {
        try await post(relayURL: relayURL, path: "/v1/recap",
                       body: RecapBody(pairing_code: pairingCode, enabled: enabled, hour: hour, minute: minute, tz_offset: tzOffset))
    }

    /// Registers this device's Live Activity push-to-start token so the relay can start an
    /// incident Live Activity on the Lock Screen even when the app is fully closed.
    static func registerActivity(relayURL: String, pairingCode: String, token: String, environment: String, kind: String = "start") async throws {
        try await post(relayURL: relayURL, path: "/v1/activity/register",
                       body: ActivityBody(pairing_code: pairingCode, token: token, environment: environment, kind: kind))
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
