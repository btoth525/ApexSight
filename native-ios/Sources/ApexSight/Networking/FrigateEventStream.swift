import Foundation

/// Live event types surfaced from Frigate's stock `/ws` relay.
enum StreamEvent {
    case review(FrigateReviewItem, ChangeType)
    case event(FrigateEvent, ChangeType)
    case stats(FrigateStats)
    case connected
    case disconnected
}

enum ChangeType: String {
    case new
    case update
    case end
}

/// Connects to Frigate's stock WebSocket (`/ws`), which relays MQTT topics as
/// `{"topic": "...", "payload": "<json-string>"}`. Auto-reconnects with backoff
/// and forwards decoded `reviews`, `events`, and `stats` to `onEvent`.
@MainActor
final class FrigateEventStream {
    var onEvent: ((StreamEvent) -> Void)?

    private var task: URLSessionWebSocketTask?
    private let urlSession: URLSession
    private var session: FrigateSession?
    private var isActive = false
    private var reconnectAttempts = 0
    private var useQueryTokenFallback = false
    private var heartbeat: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var pendingConnectedEvent = false
    /// Set while a reconnect is being scheduled/awaited so a racing receive failure and
    /// heartbeat ping failure can't both spawn a socket (which would leak the first task).
    private var isReconnecting = false

    /// A dedicated session for the long-lived `/ws` upgrade so it doesn't share connection
    /// or cache state with bulk REST/image traffic. `waitsForConnectivity` lets a connect
    /// that races device wake/network-up succeed instead of failing straight into backoff,
    /// and the shared cookie jar carries the same `frigate_token` auth as REST/AVFoundation.
    nonisolated private static let streamSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = true
        config.httpCookieStorage = .shared
        config.httpCookieAcceptPolicy = .always
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    init(urlSession: URLSession = FrigateEventStream.streamSession) {
        self.urlSession = urlSession
    }

    func connect(session: FrigateSession) {
        // Tear down any existing socket so repeated foreground events don't orphan tasks.
        if isActive { teardownSocket() }
        self.session = session
        isActive = true
        reconnectAttempts = 0
        useQueryTokenFallback = false
        isReconnecting = false
        openSocket()
    }

    private func teardownSocket() {
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeat?.cancel()
        heartbeat = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        isReconnecting = false
    }

    func disconnect() {
        isActive = false
        teardownSocket()
        onEvent?(.disconnected)
    }

    // MARK: - Socket lifecycle

    private func openSocket() {
        guard isActive, let session else { return }
        isReconnecting = false
        let client = FrigateClient(session: session)
        var request = client.webSocketRequest()

        // Fallback for reverse proxies that only honor a query-string token.
        if useQueryTokenFallback, let token = client.streamToken, let reqURL = request.url,
           var components = URLComponents(url: reqURL, resolvingAgainstBaseURL: false) {
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "token", value: token)]
            if let url = components.url { request = URLRequest(url: url) }
        }

        let socket = urlSession.webSocketTask(with: request)
        task = socket
        pendingConnectedEvent = true  // emitted on first successful message, not at resume
        socket.resume()
        receiveNext()
        startHeartbeat()
    }

    private func receiveNext() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                switch result {
                case .success(let message):
                    if self.pendingConnectedEvent {
                        self.pendingConnectedEvent = false
                        self.onEvent?(.connected)
                    }
                    self.reconnectAttempts = 0
                    // Recovered — drop back to the clean header-auth path so we don't keep
                    // appending ?token= on every later reconnect for the socket's lifetime.
                    self.useQueryTokenFallback = false
                    self.handle(message: message)
                    self.receiveNext()
                case .failure:
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, self.isActive else { return }
                // Capture THIS socket so a late ping-failure from a previous task can't tear
                // down a freshly reconnected one. Weak self so a hung ping doesn't pin us alive.
                let socket = self.task
                socket?.sendPing { [weak self] error in
                    if error != nil {
                        Task { @MainActor in
                            guard let self, self.task === socket else { return }
                            self.scheduleReconnect()
                        }
                    }
                }
            }
        }
    }

    private func scheduleReconnect() {
        // A receive failure and a heartbeat-ping failure can fire back-to-back; without this
        // guard each would tear down and re-open, orphaning the first socket/backoff task.
        guard isActive, !isReconnecting else { return }
        isReconnecting = true
        heartbeat?.cancel()
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        onEvent?(.disconnected)

        // After repeated failures, try the query-token auth variant once.
        if reconnectAttempts == 2 { useQueryTokenFallback = true }

        let delay = min(30.0, pow(2.0, Double(reconnectAttempts))) + Double.random(in: 0...0.5)
        reconnectAttempts += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.openSocket()
        }
    }

    // MARK: - Decoding

    private func handle(message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let raw): data = raw
        @unknown default: data = nil
        }
        guard let data, let envelope = try? JSONDecoder().decode(WSEnvelope.self, from: data) else { return }
        guard let payloadData = envelope.payload.data(using: .utf8) else { return }

        switch envelope.topic {
        case "reviews":
            if let wrapper = try? JSONDecoder.frigateStream.decode(ReviewUpdate.self, from: payloadData),
               let item = wrapper.after ?? wrapper.before {
                onEvent?(.review(item, ChangeType(rawValue: wrapper.type ?? "new") ?? .new))
            }
        case "events":
            if let wrapper = try? JSONDecoder.frigateStream.decode(EventUpdate.self, from: payloadData),
               let item = wrapper.after ?? wrapper.before {
                onEvent?(.event(item, ChangeType(rawValue: wrapper.type ?? "new") ?? .new))
            }
        case "stats":
            if let stats = try? JSONDecoder.frigateStream.decode(FrigateStats.self, from: payloadData) {
                onEvent?(.stats(stats))
            }
        default:
            break
        }
    }
}

// MARK: - Wire formats

private struct WSEnvelope: Decodable {
    let topic: String
    let payload: String
}

private struct ReviewUpdate: Decodable {
    let type: String?
    let before: FrigateReviewItem?
    let after: FrigateReviewItem?
}

private struct EventUpdate: Decodable {
    let type: String?
    let before: FrigateEvent?
    let after: FrigateEvent?
}

private extension JSONDecoder {
    static var frigateStream: JSONDecoder { JSONDecoder() }
}
