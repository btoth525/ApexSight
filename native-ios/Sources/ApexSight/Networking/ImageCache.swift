import UIKit

/// Tiny in-memory image cache shared across the app. Frigate snapshots and thumbnails
/// are re-requested constantly (scrolling grids, reappearing camera cells, list rows),
/// so caching the decoded `UIImage` keeps cells filled instantly instead of flashing
/// black while a fresh download runs. Bounded so it never grows unbounded.
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 240          // plenty for grids + lists
        cache.totalCostLimit = 64 * 1024 * 1024   // ~64 MB of decoded images
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func insert(_ image: UIImage, for url: URL) {
        // Cost in REAL pixels (cgImage), not points. A point-based cost under-counts @2x/@3x
        // images by 4–9x, so the 64 MB budget overfilled and evicted camera frames too early
        // (causing re-decodes / black flashes). Accurate cost = fewer evictions.
        let w = image.cgImage?.width ?? Int(image.size.width)
        let h = image.cgImage?.height ?? Int(image.size.height)
        // Animated GIFs (event/review previews) decode to N frames, but `cgImage` is only the
        // first. Bill all frames so a handful of multi-frame GIFs can't blow past the 64 MB
        // budget while the cost accounting thinks they're a single still.
        let frames = image.images?.count ?? 1
        cache.setObject(image, forKey: url as NSURL, cost: w * h * 4 * frames)
    }
}
