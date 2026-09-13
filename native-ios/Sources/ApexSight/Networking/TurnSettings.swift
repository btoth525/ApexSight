import Foundation
import WebRTC

struct IceServerConfig: Codable, Equatable {
    let urls: [String]
    let username: String?
    let credential: String?
}

/// Mints WebRTC ICE servers for remote two-way talk. On the LAN, STUN + go2rtc's host candidate
/// are enough; away from home a `cloudflared` tunnel proxies only HTTPS/WS, not the go2rtc media
/// port — so ICE needs a **TURN relay**. The relay we already run mints short-lived Cloudflare
/// Realtime TURN credentials from the pairing code the app already has (no new secret, no UI).
/// Falls back to cached creds, then to STUN-only (LAN), so talk never hard-fails to fetch.
enum TurnSettings {
    /// Last good ICE servers, kept **in memory only**. These are short-lived Cloudflare Realtime
    /// TURN credentials (a secret) minted fresh from the relay on every talk session, so the
    /// disk-persisted cache added no real resilience — a relaunch's stale creds would likely be
    /// expired anyway — while leaving the credential sitting in an unencrypted `UserDefaults` plist.
    /// In-memory keeps it as a within-session fallback without persisting the secret.
    // Written once per session after a successful fetch, read on the same path — no concurrent writers.
    private nonisolated(unsafe) static var memoryCache: [IceServerConfig]?
    private nonisolated(unsafe) static var cachedAt: Date?
    /// Cloudflare Realtime TURN credentials are minted with a multi-hour lifetime; inside this
    /// window the cached set is returned immediately and refreshed quietly, instead of a relay
    /// round-trip sitting on the critical path to first frame on every WebRTC start.
    private static let cacheLifetime: TimeInterval = 30 * 60

    /// The relay base URL + pairing code, read from the same App Group keys the rest of the
    /// relay integration uses (`apex.relayURL` / `apex.pairingCode`).
    private static func relayConfig() -> (url: URL, pairing: String)? {
        let defaults = UserDefaults(suiteName: ApexAppGroup.identifier)
        let urlString = nonEmpty(defaults?.string(forKey: "apex.relayURL")) ?? RelayConfig.defaultURL
        guard let pairing = nonEmpty(defaults?.string(forKey: "apex.pairingCode")) ?? nonEmpty(RelayConfig.defaultPairingCode),
              let url = URL(string: urlString) else { return nil }
        return (url, pairing)
    }

    /// Resolve ICE servers: always STUN, plus TURN minted by the relay (or last good cache).
    static func iceServers() async -> [RTCIceServer] {
        let stun = RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
        guard let cfg = relayConfig() else {
            return [stun] + (loadCache()?.map(rtc) ?? [])
        }
        if let fresh = loadCache(), let cachedAt, Date().timeIntervalSince(cachedAt) < cacheLifetime {
            if Date().timeIntervalSince(cachedAt) > cacheLifetime / 2 {
                Task { await refresh(cfg) }   // second half of the window: top up in the background
            }
            return [stun] + fresh.map(rtc)
        }
        if let fetched = await refresh(cfg) { return [stun] + fetched.map(rtc) }
        if let cached = loadCache() { return [stun] + cached.map(rtc) }
        return [stun]   // LAN-only fallback; the connect watchdog explains a remote failure
    }

    @discardableResult
    private static func refresh(_ cfg: (url: URL, pairing: String)) async -> [IceServerConfig]? {
        var req = URLRequest(url: cfg.url.appendingPathComponent("v1/turn-credentials"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["pairing_code": cfg.pairing])
        req.timeoutInterval = 10
        if let (data, resp) = try? await BoundedSession.relay.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let fetched = try? JSONDecoder().decode([IceServerConfig].self, from: data) {
            cache(fetched)
            return fetched
        }
        return nil
    }

    /// Whether we've ever successfully fetched TURN creds — drives the watchdog's error copy.
    static var hasRelay: Bool { loadCache() != nil }

    private static func rtc(_ c: IceServerConfig) -> RTCIceServer {
        RTCIceServer(urlStrings: c.urls, username: c.username, credential: c.credential)
    }
    private static func cache(_ s: [IceServerConfig]) {
        memoryCache = s
        cachedAt = Date()
    }
    private static func loadCache() -> [IceServerConfig]? {
        memoryCache
    }
    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }
}
