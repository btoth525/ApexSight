import SwiftUI
import UIKit

/// Auto-refreshing camera snapshot for the wall/grid. Fetches the camera's `latest.jpg` every
/// `interval` seconds (Frigate serves a fresh live frame each fetch, and `imageData` forces a
/// cache-ignoring reload for `latest.jpg`), so the grid reads as a calm, always-current wall —
/// instant, reliable, and light — while tapping a tile opens full-res live WebRTC. This is the
/// Ring/Nest/UniFi grid model: snapshots on the wall, live on tap. It sidesteps the cost and
/// cold-start lag of many simultaneous live WebRTC connections that made the live wall crawl.
///
/// Paints the last cached frame (memory, then disk) instantly on appear so a tile is never black,
/// and keeps the last good frame through a transient fetch failure instead of blanking. The
/// refresh loop is a cancellable `.task` — it stops automatically when the tile scrolls away.
struct LiveSnapshotView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    let camera: FrigateCamera
    /// A **floor** on the gap between fetches, not the cadence itself — `SnapshotPollPolicy` owns
    /// that, and stretches it whenever the server is slow or failing. Raising this slows a tile
    /// down; it cannot speed one up.
    var interval: TimeInterval = SnapshotPollPolicy.base
    /// Fires true the first time a frame is on screen (drives the host's "warming up" hint / badge).
    var onFrame: ((Bool) -> Void)? = nil

    @State private var image: Image?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        // Torn down on BACKGROUND and rebuilt on return. A backgrounded app kept polling until
        // iOS got round to suspending it — requests nobody could see the result of, landing on a
        // server that may be why the user put the app away.
        //
        // ⚠️ Keyed on `!= .background`, NOT on `== .active`, and the difference is not pedantic.
        // `.inactive` fires for a notification banner, Control Centre, the app switcher, an
        // incoming call — and rebuilding the task fetches immediately, so keying on `.active`
        // turns every banner into nine simultaneous requests. During an alert storm, which is
        // exactly when the server is loaded, that is a burst generator. `ApexSightApp` draws the
        // same line for the same reason: `.background` stops the poller, `.inactive` does not.
        .task(id: "\(camera.name)|\(scenePhase != .background)") {
            guard scenePhase != .background else { return }
            await loop()
        }
    }

    private func loop() async {
        guard camera.name != "birdseye" else { return }   // birdseye has no latest.jpg
        // Instant paint from cache (memory, then disk) so the tile is never black on appear.
        if let url = appState.client?.latestFrameURL(camera: camera.name) {
            if let cached = ImageCache.shared.image(for: url) {
                image = Image(uiImage: cached); onFrame?(true)
            } else if let disk = await Task.detached(priority: .utility, operation: {
                ImageCache.shared.diskImage(for: url)
            }).value {
                image = Image(uiImage: disk); onFrame?(true)
            }
        }
        // A rebuilt task serves out the remainder of the interval the last fetch already started,
        // so nine tiles rebuilding together don't all fetch at once.
        let initialDelay = SnapshotPollPolicy.initialDelay(sinceLastFetch: SnapshotPacer.elapsed(for: camera.name))
        if initialDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(initialDelay * 1_000_000_000))
        }

        var consecutiveFailures = 0
        var onHeartbeat = false
        while !Task.isCancelled {
            // The authoritative check, independent of whether SwiftUI re-evaluated the view: never
            // fetch a picture nobody can see. Skip-and-continue rather than return, so the loop
            // resumes on its own even if the task was never torn down and rebuilt.
            guard UIApplication.shared.applicationState != .background else {
                try? await Task.sleep(nanoseconds: UInt64(SnapshotPollPolicy.base * 1_000_000_000))
                continue
            }

            let started = Date()
            SnapshotPacer.record(camera.name, at: started)
            let ok = await fetchOnce()
            consecutiveFailures = ok ? 0 : consecutiveFailures + 1
            let next = SnapshotPollPolicy.next(
                lastDuration: ok ? Date().timeIntervalSince(started) : nil,
                consecutiveFailures: consecutiveFailures)
            // Record the transitions only — one line when the wall gives up on a camera and one
            // when it comes back. Logging every failed poll would bury everything else in the
            // black box, the same way badging every delivery trains you to ignore the badge.
            switch (next, onHeartbeat) {
            case (.heartbeat, false):
                onHeartbeat = true
                DiagnosticLog.shared.warning(
                    "wall", "\(camera.name): \(consecutiveFailures) failed snapshot fetches, dropping to 60s heartbeat")
            case (.wait, true):
                onHeartbeat = false
                DiagnosticLog.shared.info("wall", "\(camera.name): snapshots recovered")
            default:
                break
            }
            try? await Task.sleep(nanoseconds: UInt64(max(interval, next.delay) * 1_000_000_000))
        }
    }

    /// Returns whether a frame actually arrived — the caller uses that to pace the next request.
    private func fetchOnce() async -> Bool {
        guard let client = appState.client,
              let url = appState.client?.latestFrameURL(camera: camera.name) else { return false }
        do {
            let data = try await client.imageData(from: url)
            let decoded = await Task.detached(priority: .utility) {
                RemoteImage.downsample(data, maxPixel: 1200)
            }.value
            guard let ui = decoded else { return false }
            ImageCache.shared.insert(ui, for: url)
            image = Image(uiImage: ui)
            onFrame?(true)
            return true
        } catch {
            // Keep the last good frame on a transient blip / re-auth window rather than blanking.
            if error.isUnauthorized { _ = await appState.reauthenticate() }
            return false
        }
    }
}

/// A calm "warming up" indicator shown over a camera's cached snapshot until its live stream
/// produces a first frame, so a tile never reads as frozen or dead-black while connecting.
/// (Used by LiveCameraTile and the multi-camera wall.)
struct ConnectingHint: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        // Fill and self-center so the dot always sits mid-tile regardless of the parent
        // ZStack's alignment (cards align .bottom, wall cells align .bottomLeading).
        Circle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 10, height: 10)
            .scaleEffect(reduceMotion ? 1 : (breathe ? 1.0 : 0.6))
            .opacity(reduceMotion ? 0.7 : (breathe ? 0.85 : 0.35))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
            .accessibilityHidden(true)
    }
}
