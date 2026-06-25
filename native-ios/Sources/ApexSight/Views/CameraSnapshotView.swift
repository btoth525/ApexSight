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
    let camera: FrigateCamera
    var contentMode: ContentMode = .fill
    var onFrame: ((Bool) -> Void)? = nil

    @StateObject private var poller: CameraSnapshotPoller

    init(camera: FrigateCamera, contentMode: ContentMode = .fill, onFrame: ((Bool) -> Void)? = nil) {
        self.camera = camera
        self.contentMode = contentMode
        self.onFrame = onFrame
        _poller = StateObject(wrappedValue: CameraSnapshotPoller(camera: camera.name))
    }

    var body: some View {
        ZStack {
            Color.black
            if let img = poller.image {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            }
        }
        .onAppear {
            if let client = appState.client { poller.start(client: client) }
            onFrame?(poller.image != nil)
        }
        .onDisappear { poller.stop() }
        .onChange(of: poller.image == nil) { _, isNil in onFrame?(!isNil) }
    }
}
