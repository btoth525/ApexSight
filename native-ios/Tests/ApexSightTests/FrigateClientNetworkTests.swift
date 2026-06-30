import Testing
import Foundation
@testable import ApexSightNative

/// Login, request-encoding, and decode tests driven through `MockURLProtocol` so no live
/// Frigate is needed. Each test installs a handler and inspects the captured request.
@Suite("Frigate client networking", .serialized)
struct FrigateClientNetworkTests {
    // A unique host per suite avoids touching the process-wide shared cookie jar that
    // `login()`'s last-ditch fallback reads from.
    let base = URL(string: "https://frigate.test.invalid")!

    func makeClient(token: String? = nil) -> FrigateClient {
        FrigateClient(baseURL: base, token: token, session: MockURLProtocol.makeSession())
    }

    // MARK: - Login

    @Test("Login reads the JSON token field")
    func loginJSONToken() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.respond(status: 200, body: Data(#"{"token":"jwt-abc"}"#.utf8))
        let token = try await makeClient().login(username: "u", password: "p")
        #expect(token == "jwt-abc")
        // The login POST hits /api/login with a CSRF header.
        let req = try #require(MockURLProtocol.requests.last)
        #expect(req.url?.path == "/api/login")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "X-CSRF-TOKEN") == "1")
    }

    @Test("Login falls back to the Set-Cookie header when body has no token")
    func loginSetCookie() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.respond(
            status: 200,
            headers: ["Set-Cookie": "frigate_token=cookie-xyz; Path=/; HttpOnly"],
            body: Data("{}".utf8)
        )
        let token = try await makeClient().login(username: "u", password: "p")
        #expect(token == "cookie-xyz")
    }

    @Test("Login throws on empty 200 with no token anywhere")
    func loginNoTokenThrows() async {
        MockURLProtocol.reset()
        MockURLProtocol.respond(status: 200, body: Data("{}".utf8))
        await #expect(throws: FrigateError.self) {
            _ = try await makeClient().login(username: "u", password: "p")
        }
    }

    @Test("Login surfaces a 401 as a bad-response error (drives reauth)")
    func login401Throws() async {
        MockURLProtocol.reset()
        MockURLProtocol.respond(status: 401, body: Data("unauthorized".utf8))
        await #expect(throws: FrigateError.self) {
            _ = try await makeClient().login(username: "u", password: "bad")
        }
    }

    // MARK: - Request encoding

    @Test("Event filter params are URL-encoded, including camera names with spaces")
    func eventFilterEncoding() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.respond(status: 200, body: Data("[]".utf8))
        _ = try await makeClient(token: "t").events(
            camera: "Front Door", label: "person", zone: "driveway", limit: 25, hasClip: true
        )
        let req = try #require(MockURLProtocol.requests.last)
        let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(comps.path == "/api/events")
        #expect(items["camera"] == "Front Door")           // decoded value round-trips
        #expect(req.url!.absoluteString.contains("Front%20Door")) // wire form is encoded
        #expect(items["label"] == "person")
        #expect(items["zone"] == "driveway")
        #expect(items["limit"] == "25")
        #expect(items["has_clip"] == "1")
    }

    @Test("Semantic search encodes the query and requests thumbnail+description matching")
    func semanticSearchEncoding() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.respond(status: 200, body: Data("[]".utf8))
        _ = try await makeClient(token: "t").semanticSearch(query: "red car parked?", limit: 10)
        let req = try #require(MockURLProtocol.requests.last)
        let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(comps.path == "/api/events/search")
        #expect(items["query"] == "red car parked?")          // round-trips to the original
        #expect(req.url!.absoluteString.contains("red%20car%20parked"))  // spaces are encoded
        #expect(items["search_type"] == "thumbnail,description")
        #expect(items["limit"] == "10")
    }

    @Test("Reviews map reviewed:Bool → 0/1 and floor `before` to whole seconds")
    func reviewsEncoding() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.respond(status: 200, body: Data("[]".utf8))
        _ = try await makeClient(token: "t").reviews(limit: 50, severity: "alert", reviewed: true, before: 1_700_000_000.9)
        let req = try #require(MockURLProtocol.requests.last)
        let items = Dictionary(uniqueKeysWithValues:
            (URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(items["severity"] == "alert")
        #expect(items["reviewed"] == "1")
        #expect(items["before"] == "1700000000")
        #expect(items["limit"] == "50")
    }

    @Test("Mark-reviews-viewed POSTs to the documented endpoint")
    func markViewed() async throws {
        MockURLProtocol.reset()
        MockURLProtocol.respond(status: 200)
        try await makeClient(token: "t").markReviewsViewed(ids: ["a", "b", "c"])
        let req = try #require(MockURLProtocol.requests.last)
        #expect(req.url?.path == "/api/reviews/viewed")
        #expect(req.httpMethod == "POST")
    }

    // MARK: - Decoding

    @Test("Events decode with array sub_label and nested data.score/description")
    func eventsDecode() async throws {
        MockURLProtocol.reset()
        let json = """
        [{"id":"1700000000.1-aa","camera":"Front Door","label":"person",
          "sub_label":["Mail Carrier"],"has_clip":true,
          "data":{"score":0.81,"top_score":0.93,"description":"a person at the door"}}]
        """
        MockURLProtocol.respond(status: 200, body: Data(json.utf8))
        let events = try await makeClient(token: "t").events(limit: 1)
        let event = try #require(events.first)
        #expect(event.displayLabel == "Mail Carrier")  // sub_label array → first
        #expect(event.score == 0.81)                    // pulled from nested data
        #expect(event.topScore == 0.93)
        #expect(event.description == "a person at the door")
        #expect(event.hasClip == true)
    }

    @Test("Cameras decode from config and sort by name")
    func camerasDecode() async throws {
        MockURLProtocol.reset()
        let json = """
        {"cameras":{
          "Garage":{"detect":{"width":1280,"height":720},"objects":{"track":["car"]}},
          "Backyard":{"zones":{"lawn":{}},"objects":{"track":["person","dog"]}}
        }}
        """
        MockURLProtocol.respond(status: 200, body: Data(json.utf8))
        let cameras = try await makeClient(token: "t").cameras()
        #expect(cameras.map(\.name) == ["Backyard", "Garage"])   // alphabetical
        #expect(cameras.first?.objects == ["person", "dog"])
    }
}

/// Pure tests for the base-URL normalizer that decides http vs https from the host.
@Suite("Base URL normalization")
struct BaseURLNormalizationTests {
    @Test("LAN hosts default to http://")
    func lanDefaultsHTTP() throws {
        #expect(try FrigateSession.normalizedBaseURL("192.168.1.50:5000").scheme == "http")
        #expect(try FrigateSession.normalizedBaseURL("10.0.0.5").scheme == "http")
        #expect(try FrigateSession.normalizedBaseURL("172.16.4.4").scheme == "http")
        #expect(try FrigateSession.normalizedBaseURL("localhost:5000").scheme == "http")
        #expect(try FrigateSession.normalizedBaseURL("frigate.local").scheme == "http")
        #expect(try FrigateSession.normalizedBaseURL("frigate.local:8971").scheme == "http")
    }

    @Test("172.x outside 16-31 is treated as public → https")
    func publicSeventyTwo() throws {
        #expect(try FrigateSession.normalizedBaseURL("172.32.0.1").scheme == "https")
    }

    @Test("Public hostnames default to https://")
    func publicDefaultsHTTPS() throws {
        #expect(try FrigateSession.normalizedBaseURL("frigate.example.com").scheme == "https")
    }

    @Test("Explicit scheme is preserved")
    func explicitScheme() throws {
        #expect(try FrigateSession.normalizedBaseURL("http://frigate.example.com").scheme == "http")
    }

    @Test("Empty input throws")
    func emptyThrows() {
        #expect(throws: FrigateError.self) { _ = try FrigateSession.normalizedBaseURL("   ") }
    }
}
