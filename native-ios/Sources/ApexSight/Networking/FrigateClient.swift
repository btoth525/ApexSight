import Foundation
import AVFoundation

struct FrigateClient {
    private let baseURL: URL
    private let token: String?
    private let session: URLSession

    /// Shared session with real timeouts so a slow/unreachable Frigate (or proxy)
    /// fails fast instead of hanging on URLSession.shared's 60s default and stacking
    /// behind the 15s poller. `waitsForConnectivity = false` keeps offline calls from
    /// parking indefinitely. A modest disk+memory `URLCache` lets immutable assets
    /// (event thumbnails/snapshots, keyed by event id) be reused across views without
    /// a second round-trip; live `latest.jpg` frames opt out per-request (see
    /// `imageData(from:)`). Auth rides the shared cookie jar so AVFoundation and the
    /// WebSocket upgrade stay consistent with REST calls.
    static let apiSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        config.httpCookieStorage = .shared
        config.httpCookieAcceptPolicy = .always
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024,
                                   diskCapacity: 128 * 1024 * 1024,
                                   diskPath: "frigate-api")
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config)
    }()

    /// Dedicated session for large media exports (clip downloads). Streams the response body
    /// straight to disk instead of buffering the whole MP4 in memory, and lifts the resource
    /// timeout to an hour so a big clip over a slow link isn't killed mid-transfer by
    /// `apiSession`'s 60s cap. `waitsForConnectivity` rides out brief drops. Shares the cookie
    /// jar so auth stays consistent with REST calls.
    static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60
        config.waitsForConnectivity = true
        config.httpCookieStorage = .shared
        config.httpCookieAcceptPolicy = .always
        return URLSession(configuration: config)
    }()

    init(baseURL: URL, token: String? = nil, session: URLSession = FrigateClient.apiSession) {
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
        request.httpBody = try JSONEncoder.frigate.encode(["user": username, "password": password])

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
            .replacingOccurrences(of: "frigate_token=", with: "")
            .trimmingCharacters(in: .whitespaces) {
            return token
        }

        // Modern Frigate returns an empty 200 and only sets the JWT via Set-Cookie,
        // which URLSession often moves straight into the cookie jar (so the header
        // read above misses it). Read it from the jar as the reliable fallback.
        if let token = HTTPCookieStorage.shared.cookies(for: baseURL)?
            .first(where: { $0.name == "frigate_token" })?.value, !token.isEmpty {
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
                    objects: camera.objects?.track ?? [],
                    width: camera.detect?.width,
                    height: camera.detect?.height
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

    /// GenAI-generated description for a tracked object (Frigate 0.16+ with GenAI enabled).
    /// Returns nil when GenAI is off or no description has been generated yet.
    func eventDescription(id: String) async throws -> String? {
        let response: EventDescriptionResponse = try await get("api/events/\(id)")
        let text = response.data?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    func setEventDescription(id: String, description: String) async throws {
        try await post("api/events/\(id)/description", body: ["description": description])
    }

    /// Ask Frigate to regenerate the GenAI description for an event (admin + GenAI
    /// required). Generation is async server-side, so the new text arrives on a later
    /// fetch/event update, not in this response.
    func regenerateEventDescription(id: String) async throws {
        try await put("api/events/\(id)/description/regenerate", body: EmptyBody())
    }

    func reviewDescription(id: String) async throws -> String? {
        let item: FrigateReviewItem = try await get("api/review/\(id)")
        let text = item.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    func findSimilar(eventId: String, limit: Int = 20) async throws -> [FrigateEvent] {
        var components = URLComponents(url: baseURL.appending(path: "api/events/search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "event_id", value: eventId),
            URLQueryItem(name: "search_type", value: "similarity"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        guard let url = components?.url else { throw FrigateError.invalidURL }
        var request = URLRequest(url: url)
        applyAuth(to: &request)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try JSONDecoder.frigate.decode([FrigateEvent].self, from: data)
    }

    func stats() async throws -> FrigateStats {
        try await get("api/stats")
    }

    func reviews(limit: Int = 30, severity: String? = nil, reviewed: Bool? = nil, before: Double? = nil) async throws -> [FrigateReviewItem] {
        var components = URLComponents(url: baseURL.appending(path: "api/review"), resolvingAgainstBaseURL: false)
        var query = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let severity { query.append(URLQueryItem(name: "severity", value: severity)) }
        // reviewed=0 → only un-reviewed; reviewed=1 → include reviewed (Frigate default is unreviewed).
        if let reviewed { query.append(URLQueryItem(name: "reviewed", value: reviewed ? "1" : "0")) }
        if let before { query.append(URLQueryItem(name: "before", value: "\(Int(before))")) }
        components?.queryItems = query
        guard let url = components?.url else { throw FrigateError.invalidURL }
        var request = URLRequest(url: url)
        applyAuth(to: &request)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try JSONDecoder.frigate.decode([FrigateReviewItem].self, from: data)
    }

    func review(id: String) async throws -> FrigateReviewItem {
        try await get("api/review/\(id)")
    }

    func markReviewsViewed(ids: [String]) async throws {
        try await post("api/reviews/viewed", body: ReviewsViewedBody(ids: ids, reviewed: true))
    }

    private struct ReviewsViewedBody: Encodable {
        let ids: [String]
        let reviewed: Bool
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
            query.append("before=\(Int(end.timeIntervalSince1970))")
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

    /// True only when Frigate reports actual PTZ `features` (pan/tilt/zoom) for this camera.
    /// The `ptz/info` endpoint returns 200 for *every* camera (with an empty `features` list
    /// for fixed cameras), so a bare success is NOT a PTZ signal — checking `features` is what
    /// keeps the PTZ control off cameras that can't move. Yields false on any error/old Frigate.
    func ptzCapable(camera: String) async -> Bool {
        guard let info = try? await ptzInfo(camera: camera),
              case .object(let dict) = info,
              case .array(let features) = dict["features"] else { return false }
        return !features.isEmpty
    }

    /// Continuous live MJPEG stream of a camera's detect feed.
    /// Stock Frigate serves this at `/api/<camera>` (multipart/x-mixed-replace).
    /// Used as the "Lite" fallback mode when HLS fails or is unavailable.
    func mjpegURL(camera: String) -> URL {
        baseURL.appending(path: "api/\(camera)")
    }

    /// Live HLS (fMP4) via go2rtc, proxied by Frigate's main port at `/api/go2rtc/`.
    ///
    /// go2rtc's own REST API lives under `/api/go2rtc/`, so its `/api/stream.m3u8`
    /// endpoint resolves to `/api/go2rtc/api/stream.m3u8`. The valueless `mp4` flag is
    /// REQUIRED — it makes go2rtc package HLS/fMP4 that Apple's AVPlayer accepts (without
    /// it you get MPEG-TS that fails). This needs NO extra ports (1984/8555) and works
    /// through any HTTPS reverse proxy, including the Cloudflare-tunnelled auth port.
    ///
    /// - Parameter sub: request the lighter `<camera>_sub` H.264 substream (faster start,
    ///   and the safe choice for cameras whose main stream is H.265/HEVC).
    func liveHLSURL(camera: String, sub: Bool = false) -> URL {
        let streamName = sub ? "\(camera)_sub" : camera
        let endpoint = baseURL.appending(path: "api/go2rtc/api/stream.m3u8")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "src", value: streamName),
            URLQueryItem(name: "mp4", value: nil)   // renders as the bare `&mp4` flag go2rtc requires
        ]
        return components?.url ?? endpoint
    }

    func latestFrameURL(camera: String) -> URL {
        baseURL.appending(path: "api/\(camera)/latest.jpg")
    }

    /// Live frame with Frigate's overlays OFF (timestamp, bounding box, motion, regions) — for
    /// on-device AI analysis, so Vision/OCR see the real scene instead of the burned-in clock.
    func cleanFrameURL(camera: String) -> URL {
        var comps = URLComponents(url: baseURL.appending(path: "api/\(camera)/latest.jpg"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "timestamp", value: "0"),
            URLQueryItem(name: "bbox", value: "0"),
            URLQueryItem(name: "motion", value: "0"),
            URLQueryItem(name: "regions", value: "0"),
        ]
        return comps?.url ?? baseURL.appending(path: "api/\(camera)/latest.jpg")
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

    /// Progressive MP4 export of a recording range — used only for downloading a clip to
    /// Photos (a file, not a stream). For in-app *playback* use `recordingHLSURL`; Frigate's
    /// docs advise against progressive clip.mp4 for iOS playback.
    func recordingClipURL(camera: String, start: Double, end: Double) -> URL {
        baseURL.appending(path: "api/\(camera)/start/\(Int(start))/end/\(Int(end))/clip.mp4")
    }

    /// VOD HLS playlist for a recording time range — Frigate's documented endpoint
    /// (`/vod/<camera>/start/<start>/end/<end>/master.m3u8`). The iOS-recommended source
    /// for recording playback (HLS plays reliably in AVPlayer).
    func recordingHLSURL(camera: String, start: Double, end: Double) -> URL {
        baseURL.appending(path: "vod/\(camera)/start/\(Int(start))/end/\(Int(end))/master.m3u8")
    }

    /// VOD HLS playlist for a single tracked object / event — Frigate's documented
    /// `/vod/event/<event_id>/master.m3u8`. Purpose-built for event playback on iOS.
    func eventVodURL(id: String) -> URL {
        baseURL.appending(path: "vod/event/\(id)/master.m3u8")
    }

    /// Lightweight preview "frames" Frigate keeps for a recording range — its documented
    /// `GET api/preview/<camera>/start/<start>/end/<end>/frames`. Returns the timestamps of
    /// the low-res scrub-preview frames so a timeline can show a richer still while dragging.
    ///
    /// Defensive on purpose: yields `[]` on any failure (older Frigate, previews disabled,
    /// reverse-proxy quirks) so callers can treat previews as a best-effort enhancement that
    /// never blocks or breaks scrubbing.
    func previewFrameTimes(camera: String, start: Double, end: Double) async -> [Double] {
        let path = "api/preview/\(camera)/start/\(Int(start))/end/\(Int(end))/frames"
        guard let times: [Double] = try? await get(path) else { return [] }
        return times
    }

    /// URL of a single preview frame at a given epoch time — Frigate's documented
    /// `api/preview/<camera>/<timestamp>/thumbnail.jpg`. Pairs with `previewFrameTimes`
    /// to drive a continuous scrub-preview strip without a heavyweight VOD load.
    func previewFrameURL(camera: String, time: Double) -> URL {
        baseURL.appending(path: "api/preview/\(camera)/\(Int(time))/thumbnail.jpg")
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
        var params: [String: String] = [
            "query": query,
            "limit": "\(limit)",
            // Match BOTH the CLIP thumbnail embeddings AND any GenAI text descriptions
            // (Frigate's server default is "thumbnail" only). Harmless when GenAI is off
            // — it just falls back to image matching — and far better when it's on.
            "search_type": "thumbnail,description"
        ]
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

    /// Semantic search that yields `[]` instead of throwing — for fire-and-forget merges
    /// where a server without Semantic Search enabled simply contributes nothing.
    func safeSemanticSearch(
        query: String, camera: String? = nil, label: String? = nil,
        subLabel: String? = nil, zone: String? = nil,
        after: Date? = nil, before: Date? = nil, limit: Int = 50
    ) async -> [FrigateEvent] {
        (try? await semanticSearch(
            query: query, camera: camera, label: label, subLabel: subLabel,
            zone: zone, after: after, before: before, limit: limit
        )) ?? []
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

    // MARK: - Face recognition (Frigate 0.16+)

    /// Map of known face names → their training image filenames. Read-only — used to show
    /// recognized faces and power "who's home" / name-based search. (Face *management* —
    /// training/renaming/deleting — lives in Frigate's own UI.)
    func faces() async throws -> [String: [String]] {
        try await get("api/faces")
    }

    // MARK: - Camera quick controls (temporary in-memory toggles, reset on Frigate restart)

    /// Enables or disables object detection for a camera. Survives until Frigate restarts.
    func setCameraDetect(camera: String, enabled: Bool) async throws {
        try await cameraToggle(camera: camera, feature: "detect", enabled: enabled)
    }

    func setCameraRecordings(camera: String, enabled: Bool) async throws {
        try await cameraToggle(camera: camera, feature: "recordings", enabled: enabled)
    }

    func setCameraSnapshots(camera: String, enabled: Bool) async throws {
        try await cameraToggle(camera: camera, feature: "snapshots", enabled: enabled)
    }

    func setCameraAudio(camera: String, enabled: Bool) async throws {
        try await cameraToggle(camera: camera, feature: "audio", enabled: enabled)
    }

    func setCameraMotion(camera: String, enabled: Bool) async throws {
        try await cameraToggle(camera: camera, feature: "motion", enabled: enabled)
    }

    private func cameraToggle(camera: String, feature: String, enabled: Bool) async throws {
        guard var components = URLComponents(url: baseURL.appending(path: "api/\(camera)/\(feature)/set"), resolvingAgainstBaseURL: false) else { throw FrigateError.invalidURL }
        components.queryItems = [URLQueryItem(name: "enabled", value: enabled ? "1" : "0")]
        guard let url = components.url else { throw FrigateError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        applyAuth(to: &request)
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    /// Returns the enabled/disabled state for detect, recordings, snapshots, and audio
    /// for a specific camera, read from the live Frigate config.
    func cameraControlState(camera: String) async throws -> CameraControlState {
        let config: FrigateFullConfig = try await get("api/config")
        guard let cam = config.cameras[camera] else {
            return CameraControlState()
        }
        return CameraControlState(
            detect: cam.detect?.enabled ?? true,
            recordings: cam.record?.enabled ?? false,
            snapshots: cam.snapshots?.enabled ?? false,
            audio: cam.audio?.enabled ?? false,
            motion: cam.motion?.enabled ?? true
        )
    }

    /// True if a "birdseye" go2rtc stream is present (requires `birdseye.enabled` in config).
    func hasBirdseyeStream() async -> Bool {
        let streams = (try? await go2rtcStreams()) ?? [:]
        return streams["birdseye"] != nil
    }

    /// Camera names that have a `<name>_twoway` go2rtc stream — i.e. set up for two-way audio.
    func twoWayCapableCameras() async -> Set<String> {
        let streams = (try? await go2rtcStreams()) ?? [:]
        var out: Set<String> = []
        let suffix = "_twoway"
        for key in streams.keys where key.hasSuffix(suffix) {
            out.insert(String(key.dropLast(suffix.count)))
        }
        return out
    }

    /// Exchange a WebRTC offer with go2rtc for a two-way audio source and return the answer SDP.
    /// Non-trickle: the offer already carries our ICE candidates; go2rtc's answer carries its own.
    func webRTCAnswer(source: String, offerSDP: String) async throws -> String {
        let endpoint = baseURL.appending(path: "api/go2rtc/api/webrtc")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "src", value: source)]
        guard let url = components?.url else { throw FrigateError.invalidURL }
        seedCookie(for: url)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuth(to: &request)
        request.timeoutInterval = 12
        request.httpBody = try JSONSerialization.data(withJSONObject: ["type": "offer", "sdp": offerSDP])

        let (data, response) = try await session.data(for: request)
        try validate(response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sdp = json["sdp"] as? String, !sdp.isEmpty else {
            throw FrigateError.message("Malformed WebRTC answer from go2rtc")
        }
        return sdp
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
        // Live camera frames (`.../latest.jpg`) change every fetch — never serve a stale
        // cached copy. Immutable assets (event thumbnails/snapshots/gifs, keyed by id) fall
        // through to protocol caching so repeated views reuse bytes instead of re-downloading.
        if url.lastPathComponent == "latest.jpg" {
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return data
    }

    /// Streams an authenticated Frigate MP4 export to a named temp file on disk and returns its
    /// URL. Unlike `imageData(from:)` this never holds the whole clip in memory — `download(for:)`
    /// writes the body to disk as it arrives — and uses `downloadSession` so a large export over a
    /// slow link isn't cut off by the short REST resource timeout. The caller owns the returned file.
    func downloadClipFile(from url: URL, suggestedName: String) async throws -> URL {
        var request = URLRequest(url: url)
        applyAuth(to: &request)
        seedCookie(for: url)
        let (tempURL, response) = try await FrigateClient.downloadSession.download(for: request)
        try validate(response)
        // `download(for:)` writes to an unnamed temp file it deletes once this call returns, so
        // move it into a UNIQUE per-call directory that still carries the human-readable name
        // (the share sheet shows the filename). A fixed path collided when Save-to-Photos and
        // Share of the same clip ran concurrently — each call deleted the other's file mid-use.
        // Camera names come from arbitrary Frigate config, so flatten path separators.
        let safeName = suggestedName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-\(UUID().uuidString)", isDirectory: true)
        let dest = dir.appendingPathComponent(safeName).appendingPathExtension("mp4")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: tempURL, to: dest)
        } catch {
            throw ClipDownloadError.writeFailed
        }
        return dest
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
        request.httpBody = try JSONEncoder.frigate.encode(body)

        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    private func put<T: Encodable>(_ path: String, body: T) async throws {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)
        request.httpBody = try JSONEncoder.frigate.encode(body)

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

/// Decodes just the GenAI description from a full event payload (`data.description`).
private struct EventDescriptionResponse: Decodable {
    struct EventData: Decodable { let description: String? }
    let data: EventData?
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
    /// One reused decoder for all REST responses — `JSONDecoder` is thread-safe for
    /// decoding and allocating a fresh one per request is wasted work on the poll path.
    static let frigate = JSONDecoder()
}

private extension JSONEncoder {
    /// Shared request-body encoder, mirroring `JSONDecoder.frigate`.
    static let frigate = JSONEncoder()
}
