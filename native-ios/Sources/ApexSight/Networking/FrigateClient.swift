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

    func review(id: String) async throws -> FrigateReviewItem {
        try await get("api/review/\(id)")
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

    /// Continuous live MJPEG stream of a camera's detect feed.
    /// Stock Frigate serves this at `/api/<camera>` (multipart/x-mixed-replace).
    /// This is the only live transport that works natively over remote HTTPS without
    /// extra ports — go2rtc exposes NO live `.m3u8`, so AVPlayer can't stream live.
    func mjpegURL(camera: String) -> URL {
        baseURL.appending(path: "api/\(camera)")
    }

    /// go2rtc's own WebRTC player page, proxied by Frigate at /live/webrtc/webrtc.html.
    /// HD + audio; needs WebRTC connectivity (LAN always, remote needs port 8555/TURN).
    func webRTCPlayerURL(camera: String) -> URL {
        baseURL
            .appending(path: "live/webrtc/webrtc.html")
            .appending(queryItems: [URLQueryItem(name: "src", value: camera)])
    }

    func latestFrameURL(camera: String) -> URL {
        baseURL.appending(path: "api/\(camera)/latest.jpg")
    }

    /// A request with Frigate auth headers applied — for custom streamers (MJPEG).
    func authedRequest(for url: URL) -> URLRequest {
        seedCookie(for: url)
        var request = URLRequest(url: url)
        applyAuth(to: &request)
        return request
    }

    func eventSnapshotURL(id: String) -> URL {
        baseURL.appending(path: "api/events/\(id)/snapshot.jpg")
    }

    /// The cropped thumbnail around the detected object — always generated by Frigate
    /// even when full snapshots are disabled. Best choice for list rows.
    func eventThumbnailURL(id: String) -> URL {
        baseURL.appending(path: "api/events/\(id)/thumbnail.jpg")
    }

    /// Animated GIF preview of an event — used for rich notification attachments.
    func eventPreviewGifURL(id: String) -> URL {
        baseURL.appending(path: "api/events/\(id)/preview.gif")
    }

    /// Animated GIF for a review (its first detection). Rich-notification attachment.
    func reviewGifURL(review: FrigateReviewItem) -> URL? {
        guard let detectionID = review.data?.detections?.first else { return nil }
        return eventPreviewGifURL(id: detectionID)
    }

    func eventClipURL(id: String) -> URL {
        baseURL.appending(path: "api/events/\(id)/clip.mp4")
    }

    /// A review's best static image: the cropped thumbnail of its first detection.
    /// Stock Frigate has no `/review/{id}/preview` JPEG — `thumb_path` is a server
    /// filesystem path that isn't served over HTTP, so we resolve via the detection.
    func reviewThumbnailURL(review: FrigateReviewItem) -> URL? {
        guard let detectionID = review.data?.detections?.first else { return nil }
        return eventThumbnailURL(id: detectionID)
    }

    /// A larger snapshot for the review detail view: the first detection's full-frame
    /// snapshot (falls back to the cropped thumbnail when snapshots are disabled).
    func reviewSnapshotURL(review: FrigateReviewItem) -> URL? {
        guard let detectionID = review.data?.detections?.first else { return nil }
        return eventSnapshotURL(id: detectionID)
    }

    /// Direct MP4 clip for a review — AVPlayer plays this progressive file reliably.
    func reviewClipURL(id: String) -> URL {
        baseURL.appending(path: "api/review/\(id)/clip.mp4")
    }

    func recordingClipURL(camera: String, start: Double, end: Double) -> URL {
        baseURL.appending(path: "api/\(camera)/start/\(Int(start))/end/\(Int(end))/clip.mp4")
    }

    func recordingHLSURL(camera: String, start: Double, end: Double) -> URL {
        baseURL.appending(path: "vod/\(camera)/start/\(Int(start))/end/\(Int(end))/master.m3u8")
    }

    // Events with full filter params
    func events(
        camera: String? = nil,
        label: String? = nil,
        subLabel: String? = nil,
        zone: String? = nil,
        after: Date? = nil,
        before: Date? = nil,
        limit: Int = 50,
        hasClip: Bool? = nil,
        hasSnapshot: Bool? = nil
    ) async throws -> [FrigateEvent] {
        var params: [String: String] = ["limit": "\(limit)"]
        if let camera { params["camera"] = camera }
        if let label { params["label"] = label }
        if let subLabel { params["sub_label"] = subLabel }
        if let zone { params["zone"] = zone }
        if let after { params["after"] = "\(Int(after.timeIntervalSince1970))" }
        if let before { params["before"] = "\(Int(before.timeIntervalSince1970))" }
        if let hasClip { params["has_clip"] = hasClip ? "1" : "0" }
        if let hasSnapshot { params["has_snapshot"] = hasSnapshot ? "1" : "0" }

        var components = URLComponents(url: baseURL.appending(path: "api/events"), resolvingAgainstBaseURL: false)
        components?.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw FrigateError.invalidURL }
        var request = URLRequest(url: url)
        applyAuth(to: &request)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try JSONDecoder.frigate.decode([FrigateEvent].self, from: data)
    }

    // Semantic search (requires Frigate+ with embeddings enabled)
    func semanticSearch(
        query: String,
        camera: String? = nil,
        label: String? = nil,
        subLabel: String? = nil,
        zone: String? = nil,
        after: Date? = nil,
        before: Date? = nil,
        limit: Int = 50
    ) async throws -> [FrigateEvent] {
        var params: [String: String] = ["query": query, "limit": "\(limit)"]
        if let camera { params["cameras"] = camera }
        if let label { params["labels"] = label }
        if let subLabel { params["sub_labels"] = subLabel }
        if let zone { params["zones"] = zone }
        if let after { params["after"] = "\(Int(after.timeIntervalSince1970))" }
        if let before { params["before"] = "\(Int(before.timeIntervalSince1970))" }

        var components = URLComponents(url: baseURL.appending(path: "api/events/search"), resolvingAgainstBaseURL: false)
        components?.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw FrigateError.invalidURL }
        var request = URLRequest(url: url)
        applyAuth(to: &request)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try JSONDecoder.frigate.decode([FrigateEvent].self, from: data)
    }

    func retainEvent(id: String) async throws {
        try await post("api/events/\(id)/retain", body: EmptyBody())
    }

    func deleteEvent(id: String) async throws {
        let url = baseURL.appending(path: "api/events/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        applyAuth(to: &request)
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    func markFalsePositive(id: String) async throws {
        try await post("api/events/\(id)/false_positive", body: EmptyBody())
    }

    func ptzMove(camera: String, action: String, extra: [String: String] = [:]) async throws {
        var components = URLComponents(url: baseURL.appending(path: "api/\(camera)/ptz"), resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "action", value: action)]
        extra.forEach { queryItems.append(URLQueryItem(name: $0.key, value: $0.value)) }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw FrigateError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(to: &request)
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    func imageData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        applyAuth(to: &request)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return data
    }

    func playerItem(for url: URL) -> AVPlayerItem {
        seedCookie(for: url)
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": authHeaders])
        return AVPlayerItem(asset: asset)
    }

    /// Stores the `frigate_token` cookie in the shared storage so AVFoundation and
    /// URLSessionWebSocketTask upgrades both pass auth without per-request headers.
    @discardableResult
    func seedCookie(for url: URL) -> HTTPCookie? {
        guard let token, !token.isEmpty, let host = url.host else { return nil }
        let cookieProps: [HTTPCookiePropertyKey: Any] = [
            .name: "frigate_token",
            .value: token,
            .domain: host,
            .path: "/",
            .secure: url.scheme == "https"
        ]
        guard let cookie = HTTPCookie(properties: cookieProps) else { return nil }
        HTTPCookieStorage.shared.setCookie(cookie)
        return cookie
    }

    /// Authenticated upgrade request for Frigate's stock `/ws` event stream.
    /// Sends both Bearer and Cookie headers and pre-seeds the cookie jar; callers
    /// may append `?token=` as a last-resort fallback for proxies that only accept query auth.
    func webSocketRequest() -> URLRequest {
        var components = URLComponents(url: baseURL.appending(path: "ws"), resolvingAgainstBaseURL: false)
        if let scheme = components?.scheme {
            components?.scheme = (scheme == "https") ? "wss" : "ws"
        }
        let url = components?.url ?? baseURL.appending(path: "ws")
        seedCookie(for: baseURL)
        var request = URLRequest(url: url)
        applyAuth(to: &request)
        return request
    }

    /// The session token, exposed only for building the `?token=` WebSocket fallback.
    var streamToken: String? { token }

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

private struct EmptyBody: Encodable {}

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
