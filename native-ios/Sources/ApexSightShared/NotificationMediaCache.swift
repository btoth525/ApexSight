import CryptoKit
import Foundation

/// A tiny on-disk cache for notification attachment media, shared across pushes.
///
/// Why it exists: an alert arrives as **more than one push** — the instant alert, then a silent
/// follow-up that replaces it in place (same collapse id) once Frigate's AI summary and the final
/// preview exist. Each push runs the notification extension, and each extension run downloaded the
/// media again from scratch. Frigate's nginx log showed the same event's `snapshot.jpg` fetched
/// repeatedly, over a tunnel, for pictures the phone already had.
///
/// ⚠️ **GIFs are deliberately NOT cached.** `preview.gif` is built from preview frames and grows as
/// the event runs: the whole point of the final follow-up push is to carry the *completed*
/// animation. Serving the early GIF from cache would pin every alert to its first second of
/// footage — a worse bug than the redundant fetch. Only stills, whose content for a given URL is
/// stable, are reused.
///
/// Entries are short-lived (`ttl`) and the directory is pruned on write, so this can never grow
/// into a second image cache or serve something the user would read as current when it isn't.
public enum NotificationMediaCache {
    /// How long a cached still may be reused. Comfortably covers the instant → follow-up window
    /// (seconds to a minute) without holding pictures long enough to look like history.
    public static let ttl: TimeInterval = 300

    /// Cache only what is safe to reuse: a still for a specific URL. See the GIF note above.
    public static func isCacheable(_ url: URL) -> Bool {
        !url.path.lowercased().hasSuffix(".gif")
    }

    private static func directory(appGroup: String) -> URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        let dir = container.appendingPathComponent("apex-notification-media", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// SHA-256 of the absolute URL, so two different URLs can never collide onto one another's
    /// picture — in a security app the wrong frame is worse than no frame.
    public static func fileName(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension.lowercased()
        return "\(hex).\(ext)"
    }

    /// Returns a still previously downloaded for this exact URL, if it is still fresh.
    public static func cachedFile(for url: URL, appGroup: String, now: Date = Date()) -> URL? {
        guard isCacheable(url), let dir = directory(appGroup: appGroup) else { return nil }
        let file = dir.appendingPathComponent(fileName(for: url))
        guard let modified = try? FileManager.default
            .attributesOfItem(atPath: file.path)[.modificationDate] as? Date else { return nil }
        guard now.timeIntervalSince(modified) < ttl else { return nil }
        return file
    }

    /// Copies a freshly downloaded still into the cache. Failures are silent: a cache miss next
    /// time costs one fetch, while a throw here would cost the user the picture.
    @discardableResult
    public static func store(_ temporaryURL: URL, for url: URL, appGroup: String) -> Bool {
        guard isCacheable(url), let dir = directory(appGroup: appGroup) else { return false }
        let file = dir.appendingPathComponent(fileName(for: url))
        try? FileManager.default.removeItem(at: file)
        guard (try? FileManager.default.copyItem(at: temporaryURL, to: file)) != nil else { return false }
        prune(dir: dir)
        return true
    }

    /// Drops anything past its TTL. Cheap — this directory holds at most a handful of small files.
    private static func prune(dir: URL, now: Date = Date()) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, now.timeIntervalSince(modified) < ttl { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
