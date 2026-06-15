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

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func connect(session: FrigateSession) {
        // Tear down any existing socket so repeated foreground events don't orphan tasks.
        if isActive { teardownSocket() }
        self.session = session
        isActive = true
        reconnectAttempts = 0
        useQueryTokenFallback = false
        openSocket()
    }

    private func teardownSocket() {
        heartbeat?.cancel()
        heartbeat = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    func disconnect() {
        isActive = false
        teardownSocket()
        onEvent?(.disconnected)
    }

    // MARK: - Socket lifecycle

    private func openSocket() {
        guard isActive, let session else { return }
        let client = FrigateClient(session: session)
        var request = client.webSocketRequest()

        // Fallback for reverse proxies that only honor a query-string token.
        if useQueryTokenFallback, let token = client.streamToken,
           var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) {
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "token", value: token)]
            if let url = components.url { request = URLRequest(url: url) }
        }

        let socket = urlSession.webSocketTask(with: request)
        task = socket
        socket.resume()
        onEvent?(.connected)
        receiveNext()
        startHeartbeat()
    }

    private func receiveNext() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                switch result {
                case .success(let message):
                    self.reconnectAttempts = 0
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
                self.task?.sendPing { error in
                    if error != nil {
                        Task { @MainActor in self.scheduleReconnect() }
                    }
                }
            }
        }
    }

    private func scheduleReconnect() {
        guard isActive else { return }
        heartbeat?.cancel()
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        onEvent?(.disconnected)

        // After repeated failures, try the query-token auth variant once.
        if reconnectAttempts == 2 { useQueryTokenFallback = true }

        let delay = min(30.0, pow(2.0, Double(reconnectAttempts))) + Double.random(in: 0...0.5)
        reconnectAttempts += 1
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.openSocket()
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
