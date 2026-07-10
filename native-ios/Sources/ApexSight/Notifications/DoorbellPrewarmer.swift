import Foundation

/// Best-effort warm of the doorbell live stream so the video is already flowing by the time you
/// answer — the go2rtc doorbell stream is an on-demand encoder that takes a beat to spin up. Fired
/// the instant the ring push arrives (before you answer). Reads Frigate config from the app group so
/// it works even from a background / VoIP-woken launch when AppState isn't up yet.
enum DoorbellPrewarmer {
    static func warm() {
        let defaults = UserDefaults(suiteName: ApexAppGroup.identifier)
        guard let base = defaults?.string(forKey: "apex.frigateBaseURL"),
              let baseURL = URL(string: base) else { return }
        // <base>/api/go2rtc/api/stream.m3u8?src=doorbell&mp4 — hitting it starts the encoder.
        var comps = URLComponents(url: baseURL.appending(path: "api/go2rtc/api/stream.m3u8"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "src", value: "doorbell"),
                             URLQueryItem(name: "mp4", value: nil)]
        guard let url = comps?.url else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        // The baseURL may carry Basic-auth credentials; add the Bearer token too if we have one, so
        // the warm request authenticates whichever way this Frigate is fronted.
        if let token = SharedTokenStore.load(), !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // Fire-and-forget — we only need to nudge go2rtc; the answer's player then paints instantly.
        URLSession.shared.dataTask(with: req).resume()
    }
}
