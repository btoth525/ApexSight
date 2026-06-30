import Foundation

/// A `URLProtocol` that intercepts every request on a session configured with it,
/// letting tests script responses for the Frigate REST API without a live server.
///
/// Usage:
/// ```swift
/// let session = MockURLProtocol.makeSession()
/// MockURLProtocol.handler = { request in
///     (HTTPURLResponse(...), Data(...))
/// }
/// let client = FrigateClient(baseURL: url, token: "t", session: session)
/// ```
final class MockURLProtocol: URLProtocol {
    /// Set by each test. Receives the outgoing request, returns the response + body to
    /// hand back. Throw to simulate a transport error.
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// Records every request seen, so tests can assert on URL/headers/body.
    nonisolated(unsafe) static private(set) var requests: [URLRequest] = []

    static func reset() {
        handler = nil
        requests = []
    }

    /// A session whose only protocol is this mock — nothing escapes to the network.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.httpCookieStorage = HTTPCookieStorage()
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.requests.append(request)
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension MockURLProtocol {
    /// Convenience: respond with a status code and JSON/body bytes for any request.
    static func respond(status: Int = 200,
                        headers: [String: String] = [:],
                        body: Data = Data()) {
        handler = { request in
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.invalid")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (response, body)
        }
    }
}
