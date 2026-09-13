import Foundation
import WidgetKit

/// Lets the widget pull fresh data from Frigate on its own timeline schedule, so it
/// updates in the background instead of only when the app is opened. Reads the
/// base URL + token the app mirrors into the app group (same ones the notification
/// extension uses), fetches recent un-reviewed alerts + a hero thumbnail, and writes
/// them into SharedSnapshotStore. On any failure it leaves the last cache untouched.
enum WidgetDataFetcher {
    /// How many reviews to ASK for. Must stay comfortably larger than `displayCount`, because the
    /// house-mode filter runs after the fetch and can discard most of a page (see refresh()).
    static let fetchWindow = 40
    /// How many rows the widget / Watch feed actually shows.
    static let displayCount = 8

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

    /// Age of the shared feed cache. Every widget instance used to re-download the review list and
    /// hero on EVERY reload — including the reload the NSE had just triggered after writing that very
    /// cache. Providers skip the fetch when the cache is younger than this.
    static var recentAlertsAge: TimeInterval {
        let at = appGroup?.double(forKey: "apex.recentAlertsWrittenAt") ?? 0
        return at == 0 ? .infinity : Date().timeIntervalSince1970 - at
    }

    /// What the widget actually shows per row — a reload is only worth its budget when this moves.
    static func feedSignature(_ alerts: [SharedAlert]) -> [String] {
        alerts.map { "\($0.id ?? "")|\($0.subLabel ?? "")|\($0.severity)" }
    }

    /// Returns true when the visible feed CHANGED. Callers reload widget timelines only then:
    /// extension-originated reloads count against WidgetKit's ~40–70/day budget, and each alert
    /// arrives as 2–3 pushes (alert, final GIF, AI description) of which only the first moves the feed.
    @discardableResult
    static func refresh() async -> Bool {
        guard let defaults = appGroup,
              let base = defaults.string(forKey: "apex.frigateBaseURL"),
              let baseURL = URL(string: base) else { return false }
        // Token from the shared Keychain group (no longer plaintext in the App-Group plist);
        // nil simply yields an unauthenticated request, same as before.
        let token = SharedTokenStore.load()

        guard var comps = URLComponents(
            url: baseURL.appendingPathComponent("api/review"),
            resolvingAgainstBaseURL: false
        ) else { return false }
        comps.queryItems = [
            // Fetch a WINDOW, show the newest `displayCount` of what survives the house-mode
            // filter below. Fetching only 8 and then filtering has no headroom to backfill: the
            // live server right now returns 8 muted-camera rows in its first 8, so the widget
            // would write "all clear" while a Front_Driveway alert sat at position 9 — a security
            // app affirmatively saying nothing happened. At 40 the same query leaves 16 visible.
            // The Review tab already fetches 100 and filters for exactly this reason.
            URLQueryItem(name: "limit", value: String(fetchWindow)),
            URLQueryItem(name: "reviewed", value: "0")
        ]
        guard let url = comps.url else { return false }

        guard let data = await get(url, token: token) else { return false }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let reviews = try? decoder.decode([WReview].self, from: data) else { return false }
        let before = feedSignature(SharedSnapshotStore.loadRecentAlerts().alerts)

        // Same house-mode filter the Review tab applies and the relay's push gate enforces. Without
        // it the widget hero + feed, the Watch list and Siri's "latest alert" showed activity from
        // cameras the current mode silences. Reads the app's mirror; FAIL-OPEN — an empty/missing
        // mirror shows everything, exactly as before.
        let muted = SharedHouseMode.mutedCameras
        let showAll = SharedHouseMode.showAllCameras
        let unreviewed = reviews.filter {
            !($0.hasBeenReviewed ?? false)
                && HouseModeVisibility.cameraVisible($0.camera, mutedCameras: muted, showAll: showAll)
        }
        let alerts: [SharedAlert] = unreviewed
            .prefix(displayCount)
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
            return !before.isEmpty
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
        return feedSignature(alerts) != before
    }

    private static func get(_ url: URL, token: String?) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("frigate_token=\(token)", forHTTPHeaderField: "Cookie")
        }
        guard let (data, response) = try? await BoundedSession.widget.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            return nil
        }
        return data
    }
}
