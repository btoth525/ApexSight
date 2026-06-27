import AVFoundation
import SwiftUI

@main
struct ApexSightTVApp: App {
    @StateObject private var state = TVAppState()

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
        }
    }
}

/// tvOS app state: holds the Frigate session, the camera list, and a lightweight event
/// poller that powers Smart Focus on the wall. Reuses the shared FrigateClient / models /
/// KeychainStore from the iOS app.
@MainActor
final class TVAppState: ObservableObject {
    @Published var session: FrigateSession?
    @Published var cameras: [FrigateCamera] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    /// Camera with the most recent detection — drives the Smart Focus spotlight.
    @Published var activeCamera: String?

    private let keychain = KeychainStore()
    private var pollTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    private var lastEventID: String?

    var client: FrigateClient? { session.map { FrigateClient(session: $0) } }

    init() { session = keychain.loadSession() }

    func bootstrap() async {
        guard session != nil else { return }
        await loadCameras()
        startPolling()
    }

    func signIn(baseURL: String, username: String, password: String) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let normalized = try FrigateSession.normalizedBaseURL(baseURL)
            let client = FrigateClient(baseURL: normalized)
            let token = try await client.login(username: username, password: password)
            let next = FrigateSession(baseURL: normalized, username: username, token: token, password: password)
            _ = keychain.save(session: next)
            session = next
            await loadCameras()
            startPolling()
        } catch {
            errorMessage = "Couldn't connect — check the server address and your login."
        }
    }

    func loadCameras() async {
        if let cams = try? await client?.cameras() { cameras = cams }
    }

    func signOut() {
        if let session { keychain.remove(session: session) }
        pollTask?.cancel(); pollTask = nil
        clearTask?.cancel(); clearTask = nil
        session = nil
        cameras = []
        activeCamera = nil
    }

    // MARK: - Smart Focus polling

    func startPolling() {
        pollTask?.cancel()
        lastEventID = nil
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func pollOnce() async {
        guard let client else { return }
        guard let events = try? await client.events(limit: 5), let newest = events.first else { return }
        if lastEventID == nil { lastEventID = newest.id; return }   // skip the backlog on first poll
        guard newest.id != lastEventID else { return }
        lastEventID = newest.id
        spotlight(newest.camera)
    }

    private func spotlight(_ camera: String) {
        guard cameras.contains(where: { $0.name == camera }) else { return }
        clearTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { activeCamera = camera }
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { self?.activeCamera = nil }
        }
    }
}
