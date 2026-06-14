import Foundation
import AVFoundation

struct FrigateClient {
    private let baseURL: URL
    private let token: String?
    private let session: URLSession

    init(baseURL: URL, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    init(session: FrigateSession) {
        self.init(baseURL: session.baseURL, token: session.token)
    }

    func login(username: String, password: String) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "api/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-CSRF-TOKEN")
        request.httpBody = try JSONEncoder().encode(["user": username, "password": password])

        let (data, response) = try await session.data(for: request)
        try validate(response)

        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = payload["token"] as? String {
            return token
        }

        if let cookie = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Set-Cookie"),
           let token = cookie
            .split(separator: ";")
            .first(where: { $0.contains("frigate_token=") })?
            .replacingOccurrences(of: "frigate_token=", with: "") {
            return token
        }

        throw FrigateError.loginFailed
    }

    func cameras() async throws -> [FrigateCamera] {
        let config = try await config()
        return config.cameras
            .map { name, camera in
                FrigateCamera(
                    name: name,
                    zones: camera.zones?.keys.sorted() ?? [],
                    objects: camera.objects?.track ?? []
                )
            }
            .sorted { $0.name < $1.name }
    }

    func config() async throws -> FrigateConfig {
        try await get("api/config")
    }

    func events(limit: Int) async throws -> [FrigateEvent] {
        try await get("api/events?limit=\(limit)")
    }

    func event(id: String) async throws -> FrigateEvent {
        try await get("api/events/\(id)")
    }

    func stats() async throws -> FrigateStats {
        try await get("api/stats")
    }

    func reviews(limit: Int = 30) async throws -> [FrigateReviewItem] {
        try await get("api/review?limit=\(limit)")
    }

    func markReviewsViewed(ids: [String]) async throws {
        try await post("api/reviews/viewed", body: ["ids": ids])
    }

    func labels() async throws -> [String] {
        try await get("api/labels")
    }

    func subLabels() async throws -> [String] {
        try await get("api/sub_labels")
    }

    func recordings(camera: String, after: Date? = nil, end: Date? = nil) async throws -> [FrigateRecording] {
        var query: [String] = []
        if let after {
            query.append("after=\(Int(after.timeIntervalSince1970))")
        }
        if let end {
            query.append("end=\(Int(end.timeIntervalSince1970))")
        }
        let suffix = query.isEmpty ? "" : "?\(query.joined(separator: "&"))"
        return try await get("api/\(camera)/recordings\(suffix)")
    }

    func logs(service: String = "frigate") async throws -> [String] {
        let data: LogResponse = try await get("api/logs/\(service)")
        return data.lines
    }

    func go2rtcStreams() async throws -> [String: JSONValue] {
        try await get("api/go2rtc/streams")
    }

    func ptzInfo(camera: String) async throws -> JSONValue {
        try await get("api/\(camera)/ptz/info")
    }

    func latestFrameURL(camera: String) -> URL {
        baseURL.appending(path: "api/\(camera)/latest.jpg")
    }

    func eventSnapshotURL(id: String) -> URL {
        baseURL.appending(path: "api/events/\(id)/snapshot.jpg")
    }

    func eventClipURL(id: String) -> URL {
        baseURL.appending(path: "api/events/\(id)/clip.mp4")
    }

    func eventHLSURL(id: String) -> URL {
        baseURL.appending(path: "vod/event/\(id)/master.m3u8")
    }

    func reviewPreviewURL(id: String) -> URL {
        baseURL.appending(path: "api/review/\(id)/preview")
    }

    func reviewHLSURL(review: FrigateReviewItem) -> URL? {
        guard let start = review.startTime, let end = review.endTime else { return nil }
        return baseURL.appending(path: "vod/\(review.camera)/start/\(max(0, Int(start) - 2))/end/\(Int(end) + 2)/master.m3u8")
    }

    func recordingClipURL(camera: String, start: Double, end: Double) -> URL {
        baseURL.appending(path: "api/\(camera)/start/\(Int(start))/end/\(Int(end))/clip.mp4")
    }

    func recordingHLSURL(camera: String, start: Double, end: Double) -> URL {
        baseURL.appending(path: "vod/\(camera)/start/\(Int(start))/end/\(Int(end))/master.m3u8")
    }

    func imageData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        applyAuth(to: &request)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return data
    }

    func playerItem(for url: URL) -> AVPlayerItem {
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": authHeaders])
        return AVPlayerItem(asset: asset)
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        if path.contains("?"), let first = path.split(separator: "?", maxSplits: 1).first {
            components = URLComponents(url: baseURL.appending(path: String(first)), resolvingAgainstBaseURL: false)
            components?.query = String(path.split(separator: "?", maxSplits: 1).last ?? "")
        }

        guard let url = components?.url else { throw FrigateError.invalidURL }
        var request = URLRequest(url: url)
        applyAuth(to: &request)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try JSONDecoder.frigate.decode(T.self, from: data)
    }

    private func post<T: Encodable>(_ path: String, body: T) async throws {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    private func applyAuth(to request: inout URLRequest) {
        request.setValue("1", forHTTPHeaderField: "X-CSRF-TOKEN")
        authHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    }

    private var authHeaders: [String: String] {
        guard let token, !token.isEmpty else { return [:] }
        return [
            "Cookie": "frigate_token=\(token)",
            "Authorization": "Bearer \(token)"
        ]
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw FrigateError.badResponse(http.statusCode)
        }
    }
}

private struct LogResponse: Decodable {
    let lines: [String]

    init(from decoder: Decoder) throws {
        if let array = try? [String](from: decoder) {
            lines = array
            return
        }
        if let string = try? String(from: decoder) {
            lines = string.split(separator: "\n").map(String.init)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lines = (try? container.decode([String].self, forKey: .lines)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case lines
    }
}

private extension JSONDecoder {
    static var frigate: JSONDecoder {
        let decoder = JSONDecoder()
        return decoder
    }
}
