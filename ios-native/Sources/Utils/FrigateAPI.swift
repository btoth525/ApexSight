import Foundation

// MARK: - Models

struct FrigateConfig: Decodable {
    let cameras: [String: CameraConfig]
}

struct CameraConfig: Decodable {
    // Frigate config has many fields; we only need presence of the key
}

struct FrigateEvent: Decodable, Identifiable {
    let id: String
    let label: String
    let camera: String
    let startTime: Double
    let endTime: Double?
    let hasSnapshot: Bool
    let hasClip: Bool
    let score: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case camera
        case startTime = "start_time"
        case endTime = "end_time"
        case hasSnapshot = "has_snapshot"
        case hasClip = "has_clip"
        case score
    }

    var startDate: Date {
        Date(timeIntervalSince1970: startTime)
    }
}

struct LoginResponse: Decodable {
    let token: String?
    // Frigate may return success in a "success" field with token in cookie;
    // handle both patterns.
    let success: Bool?
}

// MARK: - API Client

@MainActor
final class FrigateAPI {
    static let shared = FrigateAPI()
    private init() {}

    // Base URL from UserDefaults, falling back to the default server
    var baseURL: String {
        UserDefaults.standard.string(forKey: "frigate_base_url")
            ?? "https://frigate.plexserver525.com"
    }

    private var token: String? {
        AuthManager.shared.token
    }

    // MARK: - Auth

    /// Authenticates with the Frigate server and returns a JWT token.
    func login(username: String, password: String) async throws -> String {
        let url = try makeURL("/api/login")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["user": username, "password": password]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw APIError.httpError(http.statusCode)
        }

        // Try decoding JSON body first
        if let decoded = try? JSONDecoder().decode(LoginResponse.self, from: data),
           let t = decoded.token {
            return t
        }

        // Some Frigate versions return the token in the Set-Cookie header
        if let cookieHeader = http.allHeaderFields["Set-Cookie"] as? String {
            let parts = cookieHeader.components(separatedBy: ";")
            for part in parts {
                let kv = part.trimmingCharacters(in: .whitespaces)
                if kv.hasPrefix("frigate_token=") {
                    let t = String(kv.dropFirst("frigate_token=".count))
                    if !t.isEmpty { return t }
                }
            }
        }

        throw APIError.noToken
    }

    // MARK: - Config / Camera names

    func fetchCameraNames() async throws -> [String] {
        let url = try makeURL("/api/config")
        let request = authenticatedRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)

        let config = try JSONDecoder().decode(FrigateConfig.self, from: data)
        return Array(config.cameras.keys).sorted()
    }

    // MARK: - Events

    func fetchEvents(limit: Int = 50) async throws -> [FrigateEvent] {
        var comps = URLComponents(string: baseURL + "/api/events")!
        comps.queryItems = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "has_clip", value: "1"),
        ]
        guard let url = comps.url else { throw APIError.invalidURL }
        let request = authenticatedRequest(url: url)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
        return try JSONDecoder().decode([FrigateEvent].self, from: data)
    }

    func markEventReviewed(id: String) async throws {
        let url = try makeURL("/api/events/\(id)/plus")
        var request = authenticatedRequest(url: url)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response)
    }

    // MARK: - URL helpers

    func snapshotURL(for cameraName: String) -> URL? {
        guard let t = token,
              let base = URL(string: baseURL) else { return nil }
        var comps = URLComponents(url: base.appendingPathComponent("api/\(cameraName)/latest.jpg"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "h", value: "200"),
            URLQueryItem(name: "token", value: t),
        ]
        return comps.url
    }

    func hlsURL(for cameraName: String) -> URL? {
        guard let t = token else { return nil }
        var comps = URLComponents(string: baseURL + "/live/hls/\(cameraName)/index.m3u8")!
        comps.queryItems = [URLQueryItem(name: "token", value: t)]
        return comps.url
    }

    func eventSnapshotURL(id: String) -> URL? {
        guard let t = token else { return nil }
        var comps = URLComponents(string: baseURL + "/api/events/\(id)/snapshot.jpg")!
        comps.queryItems = [URLQueryItem(name: "token", value: t)]
        return comps.url
    }

    func eventClipURL(id: String) -> URL? {
        guard let t = token else { return nil }
        var comps = URLComponents(string: baseURL + "/api/events/\(id)/clip.mp4")!
        comps.queryItems = [URLQueryItem(name: "token", value: t)]
        return comps.url
    }

    func webRTCWebSocketURL(camera: String) -> URL? {
        guard let t = token else { return nil }
        // Convert http(s) → ws(s)
        var urlString = baseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        urlString += "/live/webrtc/api/ws"
        var comps = URLComponents(string: urlString)!
        comps.queryItems = [
            URLQueryItem(name: "src", value: camera),
            URLQueryItem(name: "token", value: t),
        ]
        return comps.url
    }

    func doorbellAudioWSURL() -> URL? {
        guard let t = token else { return nil }
        var urlString = baseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        urlString += "/doorbell-audio"
        var comps = URLComponents(string: urlString)!
        comps.queryItems = [URLQueryItem(name: "token", value: t)]
        return comps.url
    }

    // MARK: - Private helpers

    private func makeURL(_ path: String) throws -> URL {
        guard let url = URL(string: baseURL + path) else {
            throw APIError.invalidURL
        }
        return url
    }

    private func authenticatedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let t = token {
            request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.httpError(http.statusCode)
        }
    }
}

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case noToken

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid server URL."
        case .invalidResponse: return "Invalid server response."
        case .httpError(let code): return "Server returned HTTP \(code)."
        case .noToken: return "Authentication failed: no token received."
        }
    }
}
