import SwiftUI
import UIKit
import ImageIO

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    /// Decode no larger than this many pixels on the long edge — keeps memory + CPU
    /// down (a 4K snapshot in an 84pt cell was decoding ~8MB; this caps it).
    var maxPixelSize: CGFloat = 1000
    /// Stale-while-revalidate: show the cached image instantly but ALSO refetch and update.
    /// Set for images whose underlying resource CHANGES — Frigate keeps improving an event's
    /// thumbnail/snapshot while the event is IN PROGRESS, so a first-frame fetch cached forever
    /// shows a stale (often subject-less) picture. Rows pass `event.endTime == nil`; when the
    /// event finishes the flag flips, the task re-fires, and one final revalidate grabs the
    /// definitive best frame.
    var revalidate: Bool = false
    /// Tried when the primary URL fails all retries (e.g. `snapshot.jpg` 404s because snapshots
    /// are disabled on that camera → fall back to the always-available cropped thumbnail).
    var fallbackURL: URL? = nil

    @EnvironmentObject private var appState: AppState
    @State private var image: Image?
    @State private var isFailed = false

    /// Re-run the load when the URL changes OR the revalidate flag flips (in-progress → done).
    private var taskKey: String { "\(url?.absoluteString ?? "")|\(revalidate)" }

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
        .task(id: taskKey) { await load() }
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
            // Fresh-enough resource → done. Changing resource (in-progress event, or the
            // one-shot refresh right after it completes) → fall through and refetch behind
            // the cached picture, then swap in the newer frame.
            if !revalidate { return }
        } else if let disk = await Task.detached(priority: .utility, operation: {
            ImageCache.shared.diskImage(for: url)
        }).value {
            // Cold-launch: the memory tier is empty, but the last-known camera frame is on disk.
            // Paint it instantly so the wall is never black, then revalidate to the live frame
            // behind it (snapshot placeholders pass `revalidate: true`).
            image = Image(uiImage: disk)
            isFailed = false
            if !revalidate { return }
        } else {
            image = nil
            isFailed = false
        }

        // A few quick retries smooth over transient network blips and the brief
        // window while an expired token is being refreshed, so a thumbnail recovers
        // on its own instead of leaving a permanent blank tile. The client is
        // re-read each pass so a freshly re-authenticated session is picked up.
        if await fetch(url) { return }
        // Primary exhausted (e.g. snapshot.jpg 404 — snapshots disabled) → try the fallback
        // (e.g. the always-available cropped thumbnail) before giving up to the placeholder.
        if let fallbackURL, await fetch(fallbackURL) { return }
        if image == nil { isFailed = true }
    }

    /// Fetch + decode one URL with retries; returns true on success (image + cache updated).
    private func fetch(_ url: URL) async -> Bool {
        let maxPixel = maxPixelSize
        for attempt in 0..<3 {
            guard let client = appState.client else { break }
            do {
                let data = try await client.imageData(from: url)
                // Decode/downsample OFF the main actor — the JPEG decode is the expensive
                // part, and doing it inline on the MainActor is what makes image-heavy
                // lists/grids stutter. Only the cache write + Image assignment hop back.
                let decoded = await Task.detached(priority: .utility) {
                    Self.downsample(data, maxPixel: maxPixel)
                }.value
                if let uiImage = decoded {
                    ImageCache.shared.insert(uiImage, for: url)
                    image = Image(uiImage: uiImage)
                    isFailed = false
                    return true
                }
            } catch {
                if error.isCancellation { return true }   // don't fall through to fallback on cancel
                // A hard 404 won't heal with retries — move on to the fallback immediately.
                if error.isNotFound { return false }
                // On an expired token, actually trigger a re-auth so the next pass picks
                // up a fresh session instead of only hoping another path refreshed it.
                if error.isUnauthorized { _ = await appState.reauthenticate() }
            }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
        return false
    }

    /// Decode-and-downsample with ImageIO so we never hold a full-resolution frame for
    /// a small cell. Falls back to a plain decode if thumbnailing fails.
    ///
    /// `nonisolated` because `RemoteImage` conforms to the `@MainActor` `View` protocol, so its
    /// members are otherwise main-actor inferred — calling this from a `Task.detached` would
    /// then warn (and silently hop the heavy decode back onto main). It only touches its
    /// arguments + ImageIO, so it's safe to run anywhere and genuinely stays off the main thread.
    nonisolated static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return UIImage(data: data)
        }
        // Animated (GIF) — keep all frames so previews actually animate.
        if CGImageSourceGetCount(source) > 1 {
            return animatedImage(from: source) ?? UIImage(data: data)
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

    // Also `nonisolated` so the GIF path runs in the same off-main decode context as `downsample`.
    nonisolated private static func animatedImage(from source: CGImageSource) -> UIImage? {
        let count = CGImageSourceGetCount(source)
        var frames: [UIImage] = []
        var duration = 0.0
        // Cap each frame like stills — an uncapped multi-frame GIF decodes N full-res frames
        // and spikes transient memory N× (preview GIFs are small, but don't rely on it).
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 900
        ]
        for index in 0..<count {
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, index, thumbOptions as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            if let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
               let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                    ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
                duration += max(delay, 0.02)
            } else {
                duration += 0.1
            }
        }
        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: duration)
    }
}
