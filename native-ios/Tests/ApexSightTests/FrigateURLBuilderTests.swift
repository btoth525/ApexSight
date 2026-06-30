import Testing
import Foundation
@testable import ApexSightNative

/// Pure-function tests for every `FrigateClient` URL builder. No network — these guard the
/// exact endpoint shapes Frigate/go2rtc expect, including the easy-to-break query encoding.
@Suite("Frigate URL builders")
struct FrigateURLBuilderTests {
    let base = URL(string: "https://frigate.example.com")!
    var client: FrigateClient { FrigateClient(baseURL: base, token: "tok") }

    // MARK: - Live streaming URLs

    @Test("HLS main stream uses go2rtc proxy path and preserves the bare mp4 flag")
    func hlsMain() throws {
        let url = client.liveHLSURL(camera: "driveway")
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        #expect(comps.path == "/api/go2rtc/api/stream.m3u8")
        let items = comps.queryItems ?? []
        #expect(items.contains(URLQueryItem(name: "src", value: "driveway")))
        // The `mp4` flag MUST be valueless — go2rtc requires the bare `&mp4` to emit
        // AVPlayer-compatible fMP4. A `mp4=` or `mp4=1` would change go2rtc's behaviour.
        let mp4 = items.first { $0.name == "mp4" }
        #expect(mp4 != nil)
        #expect(mp4?.value == nil)
        // And it must survive serialization as a bare flag, not `mp4=`.
        #expect(url.absoluteString.contains("&mp4"))
        #expect(!url.absoluteString.contains("mp4="))
    }

    @Test("HLS substream targets the _sub stream name")
    func hlsSub() throws {
        let url = client.liveHLSURL(camera: "driveway", sub: true)
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        #expect(comps.queryItems?.contains(URLQueryItem(name: "src", value: "driveway_sub")) == true)
    }

    @Test("Camera names with spaces/specials are percent-encoded in the src query")
    func hlsEncodesCameraName() throws {
        let url = client.liveHLSURL(camera: "Front Door & Porch")
        // Query encoding: space -> %20, & -> %26 inside the value.
        #expect(url.absoluteString.contains("src=Front%20Door%20%26%20Porch"))
        // Round-trips back to the original name.
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        #expect(comps.queryItems?.first { $0.name == "src" }?.value == "Front Door & Porch")
    }

    @Test("MJPEG and latest-frame URLs encode camera names into the path")
    func mjpegAndLatest() {
        #expect(client.mjpegURL(camera: "back yard").absoluteString
            == "https://frigate.example.com/api/back%20yard")
        #expect(client.latestFrameURL(camera: "back yard").absoluteString
            == "https://frigate.example.com/api/back%20yard/latest.jpg")
    }

    // MARK: - Event / review media URLs

    @Test("Event media URLs map to documented Frigate endpoints")
    func eventMedia() {
        let id = "1700000000.123-abcd"
        #expect(client.eventSnapshotURL(id: id).path == "/api/events/\(id)/snapshot.jpg")
        #expect(client.eventThumbnailURL(id: id).path == "/api/events/\(id)/thumbnail.jpg")
        #expect(client.eventPreviewGifURL(id: id).path == "/api/events/\(id)/preview.gif")
        #expect(client.eventClipURL(id: id).path == "/api/events/\(id)/clip.mp4")
        #expect(client.eventVodURL(id: id).path == "/vod/event/\(id)/master.m3u8")
    }

    @Test("Recording VOD + clip URLs floor timestamps to whole seconds")
    func recordingURLs() {
        let start = 1_700_000_000.987
        let end = 1_700_000_060.123
        #expect(client.recordingHLSURL(camera: "yard", start: start, end: end).path
            == "/vod/yard/start/1700000000/end/1700000060/master.m3u8")
        #expect(client.recordingClipURL(camera: "yard", start: start, end: end).path
            == "/api/yard/start/1700000000/end/1700000060/clip.mp4")
    }

    @Test("Preview frame URL flooring + path")
    func previewFrame() {
        #expect(client.previewFrameURL(camera: "yard", time: 1_700_000_000.9).path
            == "/api/preview/yard/1700000000/thumbnail.jpg")
    }

    // MARK: - WebSocket upgrade

    @Test("WebSocket request upgrades scheme to wss and hits /ws with auth headers")
    func webSocket() {
        let req = client.webSocketRequest()
        #expect(req.url?.scheme == "wss")
        #expect(req.url?.path == "/ws")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(req.value(forHTTPHeaderField: "Cookie") == "frigate_token=tok")
    }

    @Test("Plain-http base yields ws:// (not wss) for the socket")
    func webSocketInsecure() {
        let httpClient = FrigateClient(baseURL: URL(string: "http://192.168.1.5:5000")!, token: "tok")
        #expect(httpClient.webSocketRequest().url?.scheme == "ws")
    }

    // MARK: - Auth seeding

    @Test("Authed request carries Bearer + Cookie + CSRF headers")
    func authedRequest() {
        let req = client.authedRequest(for: client.latestFrameURL(camera: "cam"))
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(req.value(forHTTPHeaderField: "Cookie") == "frigate_token=tok")
        #expect(req.value(forHTTPHeaderField: "X-CSRF-TOKEN") == "1")
    }

    @Test("No token → no auth headers leak onto the request")
    func noTokenNoHeaders() {
        let anon = FrigateClient(baseURL: base, token: nil)
        let req = anon.authedRequest(for: anon.latestFrameURL(camera: "cam"))
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(req.value(forHTTPHeaderField: "Cookie") == nil)
    }
}
