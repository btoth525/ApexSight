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
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}
