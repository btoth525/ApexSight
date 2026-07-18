import Foundation
import WidgetKit

/// Lets the widget pull fresh data from Frigate on its own timeline schedule, so it
/// updates in the background instead of only when the app is opened. Reads the
/// base URL + token the app mirrors into the app group (same ones the notification
/// extension uses), fetches recent un-reviewed alerts + a hero thumbnail, and writes
/// them into SharedSnapshotStore. On any failure it leaves the last cache untouched.
enum WidgetDataFetcher {
    private static var appGroup: UserDefaults? { UserDefaults(suiteName: ApexAppGroup.identifier) }

    private struct WReview: Decodable {
        let id: String
        let camera: String
        let severity: String?
        let startTime: Double?
        let hasBeenReviewed: Bool?
        let data: WReviewData?
    }

    private struct WReviewData: Decodable {
        let objects: [String]?
        let subLabels: [String]?
        let detections: [String]?
        let zones: [String]?
        /// Epoch of the frame Frigate chose as this review's canonical thumbnail. Mirrors
        /// `ReviewData.thumbTime` / `FrigateClient.primaryDetectionID` — a review re-links
        /// long-lived parked tracks, so the earliest detection is often the wrong moment.
        let thumbTime: Double?
    }

    static func refresh() async {
        guard let defaults = appGroup,
              let base = defaults.string(forKey: "apex.frigateBaseURL"),
              let baseURL = URL(string: base) else { return }
        // Token from the shared Keychain group (no longer plaintext in the App-Group plist);
        // nil simply yields an unauthenticated request, same as before.
        let token = SharedTokenStore.load()

        guard var comps = URLComponents(
            url: baseURL.appendingPathComponent("api/review"),
            resolvingAgainstBaseURL: false
        ) else { return }
        comps.queryItems = [
            URLQueryItem(name: "limit", value: "8"),
            URLQueryItem(name: "reviewed", value: "0")
        ]
        guard let url = comps.url else { return }

        guard let data = await get(url, token: token) else { return }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let reviews = try? decoder.decode([WReview].self, from: data) else { return }

        let unreviewed = reviews.filter { !($0.hasBeenReviewed ?? false) }
        let alerts: [SharedAlert] = unreviewed
            .prefix(8)
            .map { r in
                SharedAlert(
                    id: r.id,
                    label: r.data?.objects?.first ?? "object",
                    subLabel: r.data?.subLabels?.first,
                    camera: r.camera,
                    severity: r.severity ?? "alert",
                    when: Date(timeIntervalSince1970: r.startTime ?? Date().timeIntervalSince1970),
                    imageFileName: nil,
                    zone: r.data?.zones?.first
                )
            }

        guard !alerts.isEmpty else {
            // Nothing un-reviewed → show "all clear".
            SharedSnapshotStore.saveRecentAlerts([], heroImageData: nil)
            return
        }

        // Hero = the detection nearest the review's `thumb_time` — the frame Frigate itself
        // chose as canonical. Frigate re-links long-lived parked tracks into fresh reviews, so
        // the EARLIEST detection is frequently a stale, wrong moment (mirrors
        // `FrigateClient.primaryDetectionID` / `bridge.py::_primary_detection` exactly, so the
        // widget hero image can never disagree with the in-app/push selection). Derive from the
        // SAME filtered list as the caption, so image and text never describe different events.
        var heroData: Data?
        func epoch(_ id: String) -> Double {
            guard let dash = id.firstIndex(of: "-"), let t = Double(id[..<dash]) else { return .greatestFiniteMagnitude }
            return t
        }
        func primaryDetectionID(_ review: WReview?) -> String? {
            let ids = review?.data?.detections ?? []
            guard !ids.isEmpty else { return nil }
            if let tt = review?.data?.thumbTime {
                let atOrBefore = ids.filter { epoch($0) <= tt + 1 }
                if let best = atOrBefore.max(by: { epoch($0) < epoch($1) }) { return best }
                // thumb_time precedes every detection (rare) → the closest one.
                return ids.min(by: { abs(epoch($0) - tt) < abs(epoch($1) - tt) })
            }
            // No thumb_time yet (in-progress review) → earliest = the trigger detection.
            return ids.min { epoch($0) < epoch($1) }
        }
        if let detectionID = primaryDetectionID(unreviewed.first) {
            let thumbURL = baseURL.appendingPathComponent("api/events/\(detectionID)/thumbnail.jpg")
            heroData = await get(thumbURL, token: token)
        }

        SharedSnapshotStore.saveRecentAlerts(alerts, heroImageData: heroData)
    }

    private static func get(_ url: URL, token: String?) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("frigate_token=\(token)", forHTTPHeaderField: "Cookie")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            return nil
        }
        return data
    }
}
