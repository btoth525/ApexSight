import Foundation

/// A user-configured video feed: a name, a URL and how to play it. Feeds are just URLs — no
/// camera-specific control. Frigate cameras can be added in one tap (MJPEG, signed with the
/// app's session), any other HLS / MP4 / MJPEG / H.264 URL by hand.
struct Feed: Codable, Identifiable, Equatable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case hls, mp4, mjpeg, h264
        var id: String { rawValue }
        var title: String {
            switch self {
            case .hls: return "HLS"
            case .mp4: return "MP4"
            case .mjpeg: return "MJPEG"
            case .h264: return "H.264"
            }
        }
        /// Played by AVPlayer (system HLS/progressive pipeline) rather than the raw byte client.
        var usesAVPlayer: Bool { self == .hls || self == .mp4 }
    }

    var id = UUID()
    var name: String
    var url: URL
    var kind: Kind
    /// Sign requests with the signed-in Frigate session (feeds seeded from the camera list).
    var usesFrigateAuth = false

    /// Best guess from the URL. Nil = ask the user.
    static func detectKind(from url: URL) -> Kind? {
        let path = url.path.lowercased()
        let full = url.absoluteString.lowercased()
        if path.hasSuffix(".m3u8") { return .hls }
        if path.hasSuffix(".mp4") || path.hasSuffix(".mov") { return .mp4 }
        if full.contains("mjpg") || full.contains("mjpeg") || full.contains("/stream") || full.contains("x-mixed") { return .mjpeg }
        if full.contains("h264") || full.contains("264") { return .h264 }
        return nil
    }

    /// RTSP/RTMP aren't playable here (no library, by design) — say so before a doomed connect.
    static func unsupportedSchemeMessage(for url: URL) -> String? {
        switch url.scheme?.lowercased() {
        case "rtsp", "rtsps": return "RTSP isn't supported — use the camera's HLS (.m3u8) or MJPEG URL instead."
        case "rtmp", "rtmps": return "RTMP isn't supported — use an HLS (.m3u8) or MJPEG URL instead."
        default: return nil
        }
    }
}

/// Persisted feed list. Edited on the phone (Settings › Video Feeds), chosen on the car.
@MainActor
final class FeedStore: ObservableObject {
    static let shared = FeedStore()

    private let key = "apex.feeds"
    private let lastKey = "apex.feeds.last"

    @Published private(set) var feeds: [Feed] {
        didSet {
            if let data = try? JSONEncoder().encode(feeds) { UserDefaults.standard.set(data, forKey: key) }
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Feed].self, from: data) {
            feeds = decoded
        } else {
            feeds = []
        }
    }

    func add(_ feed: Feed) { feeds.append(feed) }
    func remove(_ feed: Feed) { feeds.removeAll { $0.id == feed.id } }
    func remove(at offsets: IndexSet) { feeds.remove(atOffsets: offsets) }
    func move(from source: IndexSet, to destination: Int) { feeds.move(fromOffsets: source, toOffset: destination) }
    func update(_ feed: Feed) {
        if let index = feeds.firstIndex(where: { $0.id == feed.id }) { feeds[index] = feed }
    }

    var lastSelectedID: UUID? {
        get { UserDefaults.standard.string(forKey: lastKey).flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: lastKey) }
    }

    /// The feed to resume: the last one played, else the first.
    var resumeFeed: Feed? {
        if let id = lastSelectedID, let feed = feeds.first(where: { $0.id == id }) { return feed }
        return feeds.first
    }

    /// One tap: every Frigate camera as a signed MJPEG feed (skips ones already present).
    func addFrigateCameras(_ names: [String], client: FrigateClient) -> Int {
        var added = 0
        for name in names where name != "birdseye" {
            let url = client.mjpegURL(camera: name)
            guard !feeds.contains(where: { $0.url == url }) else { continue }
            feeds.append(Feed(name: titleize(name), url: url, kind: .mjpeg, usesFrigateAuth: true))
            added += 1
        }
        return added
    }
}
