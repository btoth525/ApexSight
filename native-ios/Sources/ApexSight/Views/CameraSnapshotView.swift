import ImageIO
import SwiftUI
import UIKit

/// Auto-refreshing camera still for the grid. Instead of running a full live WebRTC stream
/// in every tile at once (heavy, choppy, and it fights the full-screen stream for the same
/// camera), each tile polls the camera's `latest.jpg` every couple seconds — one small JPEG,
/// decoded off the main thread. The wall stays smooth and instant, and tapping a card opens
/// the single full-screen live stream with nothing competing for the connection.
@MainActor
final class CameraSnapshotPoller: ObservableObject {
    @Published private(set) var image: UIImage?

    private let camera: String
    private let intervalNanos: UInt64
    private var task: Task<Void, Never>?

    init(camera: String, interval: Double = 2.0) {
        self.camera = camera
        self.intervalNanos = UInt64(interval * 1_000_000_000)
    }

    func start(client: FrigateClient) {
        guard task == nil else { return }
        // Paint instantly from the prewarmed cache (keyed by the stable URL) if present.
        if image == nil, let cached = ImageCache.shared.image(for: client.latestFrameURL(camera: camera)) {
            image = cached
        }
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.fetchOnce(client: client)
                try? await Task.sleep(nanoseconds: self.intervalNanos)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func fetchOnce(client: FrigateClient) async {
        let stableURL = client.latestFrameURL(camera: camera)
        // Cache-bust the request so we actually get a fresh frame each poll…
        let fetchURL = Self.busted(stableURL)
        guard let data = try? await client.imageData(from: fetchURL) else { return }
        let decoded = await Task.detached(priority: .utility) { Self.decode(data) }.value
        guard let decoded, !Task.isCancelled else { return }
        image = decoded
        // …but store under the STABLE key so prewarm/other placeholders see the fresh frame too.
        ImageCache.shared.insert(decoded, for: stableURL)
    }

    private static func busted(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970 * 1000))))
        comps.queryItems = items
        return comps.url ?? url
    }

    nonisolated static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 900,
              ] as CFDictionary) else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }
}

/// The grid tile view: shows the polled still, fits the camera's real aspect inside the tile
/// (so ultra-wide cameras aren't cropped to where the subject is off-screen), and reports
/// when it has a frame so the card's status dot can go green.
struct CameraSnapshotView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let camera: FrigateCamera
    var contentMode: ContentMode = .fit
    var onFrame: ((Bool) -> Void)? = nil

    @StateObject private var poller: CameraSnapshotPoller

    init(camera: FrigateCamera, contentMode: ContentMode = .fit, onFrame: ((Bool) -> Void)? = nil) {
        self.camera = camera
        self.contentMode = contentMode
        self.onFrame = onFrame
        _poller = StateObject(wrappedValue: CameraSnapshotPoller(camera: camera.name))
    }

    var body: some View {
        // Color.black takes the tile's size; the image is drawn as an OVERLAY sized to that
        // box and clipped — so a wide frame can never blow past the tile and fill the screen.
        // `.fit` shows the whole scene (ultra-wide isn't cropped/zoomed); the tile letterboxes.
        Color.black
            .overlay {
                if let img = poller.image {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
                } else {
                    // Calm loading affordance instead of a dead black box while the first
                    // frame is still on its way.
                    ConnectingHint()
                }
            }
            .clipped()
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: poller.image == nil)
            .onAppear {
                if let client = appState.client { poller.start(client: client) }
                onFrame?(poller.image != nil)
            }
            .onDisappear { poller.stop() }
            .onChange(of: poller.image == nil) { _, isNil in onFrame?(!isNil) }
    }
}

/// A calm "still connecting" affordance for live/snapshot tiles: a single soft, slowly
/// breathing dot over the dark base — never a jarring spinner. Used behind grid tiles so a
/// camera that hasn't delivered a frame yet reads as "warming up," not broken or frozen.
/// Respects Reduce Motion (holds steady, no continuous pulse).
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
