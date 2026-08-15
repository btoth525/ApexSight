import Foundation

/// Sessions that talk to Frigate with a **total** time budget, not just an idle one.
///
/// ⚠️ `URLRequest.timeoutInterval` is an IDLE timeout — it measures the gap between packets, so a
/// server that trickles one byte every few seconds resets it forever. Frigate answers several
/// endpoints (`preview.gif`, event snapshots, clip/recording exports) by spawning an ffmpeg and
/// streaming its pipe, and over a slow link those trickle. A request with only `timeoutInterval`
/// set can therefore hang far past its apparent limit, and `URLSession.shared` — which every
/// extension in this app was using — caps the total at **7 days**.
///
/// That is not merely a slow client: when the client finally walks away, nobody is reading
/// ffmpeg's pipe. ffmpeg blocks on a full buffer, never exits, and holds a Frigate API worker.
/// Measured on this household's server (2026-08-14): 40 orphaned `playlist_*` exports leaked at
/// roughly one per 22 minutes until the worker pool was exhausted and the whole Frigate API went
/// unresponsive for ~7 hours, with nginx logging `499` at `request_time="125.0"` for the app's
/// own user agents. Killing exactly those 40 processes restored the API instantly.
///
/// So every session pointed at Frigate sets `timeoutIntervalForResource` (a wall-clock cap no
/// amount of trickling can extend) and `HTTPMaximumConnectionsPerHost` (so a nine-camera grid
/// cannot open nine simultaneous exports). Abandoning a request still costs the server an ffmpeg
/// — the point is to bound how many can be in flight and how long each may live.
public enum BoundedSession {

    /// - Parameters:
    ///   - idle: gap-between-packets cap (`timeoutIntervalForRequest`).
    ///   - total: wall-clock cap for the whole transfer (`timeoutIntervalForResource`). This is
    ///     the one that actually stops a trickling ffmpeg pipe from being held open.
    ///   - maxConnectionsPerHost: ceiling on simultaneous requests to Frigate.
    public static func make(idle: TimeInterval,
                            total: TimeInterval,
                            maxConnectionsPerHost: Int = 2) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = idle
        config.timeoutIntervalForResource = total
        config.httpMaximumConnectionsPerHost = maxConnectionsPerHost
        // Never park an offline request waiting for connectivity — in an extension that just
        // burns the (short) execution budget, and in the app it stacks work behind a poller.
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    /// Notification-service media (`preview.gif`, event snapshots). iOS gives the extension a hard
    /// ~30s budget before it kills it and delivers the notification without media, so the total is
    /// set well inside that: a killed extension abandons its request, which is exactly the 499 that
    /// orphans an ffmpeg. Better to give up at 12s and try the next candidate — the alert still
    /// arrives, just without a picture.
    public static let notificationMedia: URLSession = make(idle: 8, total: 12, maxConnectionsPerHost: 2)

    /// Widget timeline refreshes. These fire on the system's schedule with no regard for whether
    /// the previous batch returned, so a slow server must not let them accumulate.
    public static let widget: URLSession = make(idle: 8, total: 15, maxConnectionsPerHost: 2)
}
