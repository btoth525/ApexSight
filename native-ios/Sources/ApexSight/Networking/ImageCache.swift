import UIKit
import CryptoKit

/// Shared image cache: an in-memory tier (instant, bounded) backed by a small on-disk tier
/// for **camera snapshots** (`latest.jpg`) so the very first paint after a cold launch is the
/// last-known frame instead of a black tile.
///
/// Frigate snapshots and thumbnails are re-requested constantly (scrolling grids, reappearing
/// camera cells, list rows), so caching the decoded `UIImage` keeps cells filled instantly
/// instead of flashing black while a fresh download runs. The memory tier is bounded so it never
/// grows unbounded; the disk tier is scoped to `latest.jpg` (the camera wall) and size-capped so
/// event thumbnails can't churn it out.
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSURL, UIImage>()

    /// Disk tier — only camera snapshots land here so the wall paints instantly on cold launch.
    private let diskDir: URL?
    /// Serialize disk writes/trims off the main thread. Reads use `Data(contentsOf:)` directly
    /// (already called from a detached task in `RemoteImage`), so they don't need this queue.
    private let diskQueue = DispatchQueue(label: "com.apexsight.imagecache.disk", qos: .utility)
    /// Keep the on-disk snapshot cache small — a dozen cameras at ~1000px JPEG is well under this.
    private let diskBudgetBytes = 32 * 1024 * 1024

    private init() {
        cache.countLimit = 240          // plenty for grids + lists
        cache.totalCostLimit = 64 * 1024 * 1024   // ~64 MB of decoded images

        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let dir = base?.appendingPathComponent("ApexSnapshotCache", isDirectory: true)
        if let dir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        diskDir = dir
        // Trim the disk tier down to budget in the background so a long-running install can't
        // let it grow without bound (the OS also purges Caches under storage pressure).
        diskQueue.async { [weak self] in self?.trimDiskToBudget() }
    }

    // MARK: Memory tier

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func insert(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL, cost: cost(of: image))
        // Persist ONLY camera snapshots so the wall can paint last-known frames on the next cold
        // launch. Scoping to `latest.jpg` keeps the many event/review thumbnails from evicting the
        // handful of camera frames that actually matter here.
        if url.lastPathComponent == "latest.jpg" {
            persistToDisk(image, for: url)
        }
    }

    private func cost(of image: UIImage) -> Int {
        // Cost in REAL pixels (cgImage), not points. A point-based cost under-counts @2x/@3x
        // images by 4–9x, so the 64 MB budget overfilled and evicted camera frames too early
        // (causing re-decodes / black flashes). Accurate cost = fewer evictions.
        let w = image.cgImage?.width ?? Int(image.size.width)
        let h = image.cgImage?.height ?? Int(image.size.height)
        // Animated GIFs (event/review previews) decode to N frames, but `cgImage` is only the
        // first. Bill all frames so a handful of multi-frame GIFs can't blow past the 64 MB
        // budget while the cost accounting thinks they're a single still.
        let frames = image.images?.count ?? 1
        return w * h * 4 * frames
    }

    // MARK: Disk tier (camera snapshots only)

    /// Last-known frame from disk, if any. Promotes the hit back into the memory tier so
    /// subsequent lookups are instant. Safe to call off the main thread. Scoped to camera
    /// snapshots — the only thing the write side persists — so thumbnail-heavy scrolls don't
    /// eat a filesystem miss per cell.
    func diskImage(for url: URL) -> UIImage? {
        guard url.lastPathComponent == "latest.jpg",
              let file = diskFile(for: url),
              let data = try? Data(contentsOf: file),
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL, cost: cost(of: image))
        return image
    }

    private func persistToDisk(_ image: UIImage, for url: URL) {
        guard let file = diskFile(for: url), let data = image.jpegData(compressionQuality: 0.7) else { return }
        diskQueue.async {
            try? data.write(to: file, options: .atomic)
        }
    }

    private func diskFile(for url: URL) -> URL? {
        guard let diskDir else { return nil }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent(name).appendingPathExtension("jpg")
    }

    /// Evict the oldest files until the disk tier is under budget. Runs on `diskQueue`.
    private func trimDiskToBudget() {
        guard let diskDir else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: diskDir, includingPropertiesForKeys: keys
        ) else { return }
        var total = 0
        var entries: [(url: URL, size: Int, modified: Date)] = []
        for file in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            let size = values?.fileSize ?? 0
            total += size
            entries.append((file, size, values?.contentModificationDate ?? .distantPast))
        }
        guard total > diskBudgetBytes else { return }
        for entry in entries.sorted(by: { $0.modified < $1.modified }) {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
            if total <= diskBudgetBytes { break }
        }
    }
}
