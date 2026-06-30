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
    private static let cacheKey = "cachedIceServers"

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
        var req = URLRequest(url: cfg.url.appendingPathComponent("v1/turn-credentials"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["pairing_code": cfg.pairing])
        req.timeoutInterval = 10
        if let (data, resp) = try? await URLSession.shared.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let fetched = try? JSONDecoder().decode([IceServerConfig].self, from: data) {
            cache(fetched)
            return [stun] + fetched.map(rtc)
        }
        if let cached = loadCache() { return [stun] + cached.map(rtc) }
        return [stun]   // LAN-only fallback; the connect watchdog explains a remote failure
    }

    /// Whether we've ever successfully fetched TURN creds — drives the watchdog's error copy.
    static var hasRelay: Bool { loadCache() != nil }

    private static func rtc(_ c: IceServerConfig) -> RTCIceServer {
        RTCIceServer(urlStrings: c.urls, username: c.username, credential: c.credential)
    }
    private static func cache(_ s: [IceServerConfig]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: cacheKey)
    }
    private static func loadCache() -> [IceServerConfig]? {
        guard let d = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode([IceServerConfig].self, from: d)
    }
    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }
}
