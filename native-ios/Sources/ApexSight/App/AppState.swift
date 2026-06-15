import Foundation
import SwiftUI

enum AppDeepLink: Hashable {
    case review(String)
    case event(String)
    case camera(String)
}

extension Error {
    /// True for URLSession/Task cancellations that shouldn't surface as user-facing errors.
    var isCancellation: Bool {
        if self is CancellationError { return true }
        let nsError = self as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var session: FrigateSession?
    @Published var cameras: [FrigateCamera] = []
    @Published var events: [FrigateEvent] = []
    @Published var reviews: [FrigateReviewItem] = []
    @Published var labels: [String] = []
    @Published var subLabels: [String] = []
    @Published var stats: FrigateStats?
    @Published var capabilities: [CameraCapability] = []
    @Published var recentLogs: [String] = []
    @Published var deepLink: AppDeepLink?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isLive = false
    @Published var liveBanner: LiveBannerModel?

    let keychain = KeychainStore()
    let notificationPrefs = NotificationPreferencesStore()
    private let eventStream = FrigateEventStream()

    var client: FrigateClient? {
        guard let session else { return nil }
        return FrigateClient(session: session)
    }

    init() {
        session = keychain.loadSession()
        eventStream.onEvent = { [weak self] event in
            self?.handleStreamEvent(event)
        }
    }

    // MARK: - Real-time

    func startRealtime() {
        guard let session else { return }
        eventStream.connect(session: session)
    }

    func stopRealtime() {
        eventStream.disconnect()
    }

    private func handleStreamEvent(_ event: StreamEvent) {
        switch event {
        case .connected:
            isLive = true
        case .disconnected:
            isLive = false
        case .stats(let s):
            stats = s
        case .event(let item, _):
            upsertEvent(item)
        case .review(let item, let change):
            handleReview(item, change: change)
        }
    }

    private func upsertEvent(_ item: FrigateEvent) {
        events.removeAll { $0.id == item.id }
        events.insert(item, at: 0)
        if events.count > 50 { events = Array(events.prefix(50)) }
    }

    private func handleReview(_ item: FrigateReviewItem, change: ChangeType) {
        let wasNew = !reviews.contains { $0.id == item.id }
        reviews.removeAll { $0.id == item.id }
        if change != .end {
            reviews.insert(item, at: 0)
            if reviews.count > 30 { reviews = Array(reviews.prefix(30)) }
        }

        guard wasNew, change == .new, item.severity == "alert" else { return }

        let label = item.data?.objects?.first ?? "object"
        let zones = item.data?.zones ?? []
        guard notificationPrefs.shouldDeliver(camera: item.camera, label: label, zones: zones) else { return }
        guard LastSeenStore.isNew(item.id) else { return }
        LastSeenStore.markSeen([item.id])

        liveBanner = LiveBannerModel(
            id: item.id,
            title: NotificationCopy.title(for: item),
            body: NotificationCopy.body(for: item),
            reviewID: item.id
        )

        IncidentActivityController.startOrUpdate(review: item)

        if let client, let session {
            Task { await LocalAlertNotifier.notify(review: item, client: client, session: session) }
        }
    }

    func signIn(baseURL: String, username: String, password: String) async {
        isLoading = true
        errorMessage = nil
        do {
            let normalized = try FrigateSession.normalizedBaseURL(baseURL)
            let client = FrigateClient(baseURL: normalized)
            let token = try await client.login(username: username, password: password)
            let next = FrigateSession(baseURL: normalized, username: username, token: token)
            keychain.save(session: next)
            session = next
            await refresh()
            startRealtime()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func refresh() async {
        guard let client else { return }
        isLoading = true
        errorMessage = nil
        do {
            async let nextCameras = client.cameras()
            async let nextEvents = client.events(limit: 50)
            async let nextReviews = client.reviews(limit: 30)
            async let nextLabels = client.labels()
            async let nextSubLabels = client.subLabels()
            async let nextStats = client.stats()
            async let nextLogs = client.logs()
            async let nextStreams = client.go2rtcStreams()

            let loadedCameras = try await nextCameras
            cameras = loadedCameras
            events = try await nextEvents
            reviews = (try? await nextReviews) ?? reviews
            labels = (try? await nextLabels) ?? labels
            subLabels = (try? await nextSubLabels) ?? subLabels
            if let s = try? await nextStats { stats = s }
            recentLogs = (try? await nextLogs) ?? recentLogs

            let streams = (try? await nextStreams) ?? [:]
            await cacheWidgetSnapshot(from: loadedCameras)
            capabilities = buildBaseCapabilities(cameras: loadedCameras, streams: streams)
        } catch {
            // Ignore transient cancellations (interrupted refreshes, view teardown).
            if !error.isCancellation {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    private func cacheWidgetSnapshot(from cameras: [FrigateCamera]) async {
        guard
            let client,
            let camera = cameras.first,
            let serverName = session?.baseURL.host()
        else {
            return
        }

        do {
            let data = try await client.imageData(from: client.latestFrameURL(camera: camera.name))
            SharedSnapshotStore.save(imageData: data, camera: camera.name, serverName: serverName)
        } catch {}
    }

    private func buildBaseCapabilities(cameras: [FrigateCamera], streams: [String: JSONValue]) -> [CameraCapability] {
        cameras.map { camera in
            CameraCapability(
                camera: camera.name,
                hasLatestFrame: true,
                hasGo2RtcStream: streams[camera.name] != nil,
                zones: camera.zones,
                objects: camera.objects
            )
        }
        .sorted { $0.camera < $1.camera }
    }

    func refreshCapabilityDiagnostics() async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }

        let diagnosed = await buildCapabilityDiagnostics(cameras: cameras, client: client)
        if !diagnosed.isEmpty {
            capabilities = diagnosed
        }
    }

    private func buildCapabilityDiagnostics(cameras: [FrigateCamera], client: FrigateClient) async -> [CameraCapability] {
        let knownCapabilities = Dictionary(uniqueKeysWithValues: capabilities.map { ($0.camera, $0) })
        var output: [CameraCapability] = []

        for camera in cameras {
            let known = knownCapabilities[camera.name]
            var capability = CameraCapability(
                camera: camera.name,
                hasGo2RtcStream: known?.hasGo2RtcStream ?? false,
                zones: camera.zones,
                objects: camera.objects
            )

            do {
                _ = try await client.imageData(from: client.latestFrameURL(camera: camera.name))
                capability.hasLatestFrame = true
            } catch {}

            do {
                capability.hasRecordings = !(try await client.recordings(camera: camera.name)).isEmpty
            } catch {}

            do {
                _ = try await client.ptzInfo(camera: camera.name)
                capability.hasPtz = true
            } catch {}

            output.append(capability)
        }

        return output.sorted { $0.camera < $1.camera }
    }

    func switchTo(session: FrigateSession) {
        stopRealtime()
        self.session = session
        keychain.save(session: session)
        cameras = []
        events = []
        reviews = []
        labels = []
        subLabels = []
        stats = nil
        capabilities = []
        recentLogs = []
        Task {
            await refresh()
            startRealtime()
        }
    }

    func signOut() {
        stopRealtime()
        keychain.clear()
        session = nil
        cameras = []
        events = []
        reviews = []
        labels = []
        subLabels = []
        stats = nil
        capabilities = []
        recentLogs = []
    }

    func markReviewViewed(_ review: FrigateReviewItem) async {
        await markReviewViewed(id: review.id)
    }

    func markReviewViewed(id: String) async {
        guard let client else { return }
        do {
            try await client.markReviewsViewed(ids: [id])
            reviews.removeAll { $0.id == id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme == "apex" else { return }

        let target = url.host ?? url.pathComponents.dropFirst().first
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []

        switch target {
        case "review":
            if let id = items.first(where: { $0.name == "id" })?.value {
                deepLink = .review(id)
            }
        case "event":
            if let id = items.first(where: { $0.name == "id" })?.value {
                deepLink = .event(id)
            }
        case "camera":
            if let name = items.first(where: { $0.name == "name" })?.value {
                deepLink = .camera(name)
            }
        default:
            break
        }
    }
}
