import SwiftUI
import UIKit
import ImageIO

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    /// Decode no larger than this many pixels on the long edge — keeps memory + CPU
    /// down (a 4K snapshot in an 84pt cell was decoding ~8MB; this caps it).
    var maxPixelSize: CGFloat = 1000

    @EnvironmentObject private var appState: AppState
    @State private var image: Image?
    @State private var isFailed = false

    var body: some View {
        ZStack {
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if isFailed {
                placeholder
            } else {
                placeholder
                    .overlay { ProgressView().tint(GlassTheme.cyan) }
            }
        }
        .task(id: url) { await load() }
    }

    private var placeholder: some View {
        ZStack {
            Color.white.opacity(0.06)
            Image(systemName: "photo")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(GlassTheme.secondary)
        }
    }

    private func load() async {
        guard let url else {
            isFailed = true
            return
        }
        // Show the cached image instantly — no black flash when a cell reappears.
        if let cached = ImageCache.shared.image(for: url) {
            image = Image(uiImage: cached)
            isFailed = false
            return
        }
        image = nil
        isFailed = false

        // A few quick retries smooth over transient network blips and the brief
        // window while an expired token is being refreshed, so a thumbnail recovers
        // on its own instead of leaving a permanent blank tile. The client is
        // re-read each pass so a freshly re-authenticated session is picked up.
        for attempt in 0..<3 {
            guard let client = appState.client else { break }
            do {
                let data = try await client.imageData(from: url)
                if let uiImage = Self.downsample(data, maxPixel: maxPixelSize) {
                    ImageCache.shared.insert(uiImage, for: url)
                    image = Image(uiImage: uiImage)
                    isFailed = false
                    return
                }
            } catch {
                if error.isCancellation { return }
            }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
        isFailed = true
    }

    /// Decode-and-downsample with ImageIO so we never hold a full-resolution frame for
    /// a small cell. Falls back to a plain decode if thumbnailing fails.
    static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cg)
    }
}
