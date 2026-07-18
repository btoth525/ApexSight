import Foundation

enum ApexAppGroup {
    static let identifier = "group.com.brandontoth.apexsight"
}

struct SharedCameraSnapshot: Codable, Hashable {
    let camera: String
    let serverName: String
    let capturedAt: Date
    let imageFileName: String
}

struct SharedAlert: Codable, Hashable, Identifiable {
    var id: String? = nil    // review id — lets the widget deep-link straight to the event
    let label: String        // e.g. "person", "car"
    let subLabel: String?    // e.g. a recognized face/plate, may be nil
    let camera: String
    let severity: String     // "alert" or "detection"
    let when: Date
    let imageFileName: String?  // nil when no thumbnail was cached
    var zone: String? = nil  // first zone the object was in, if any
}

enum SharedSnapshotStore {
    private static let defaultsKey = "latest-camera-snapshot"
    private static let imageFileName = "latest-camera.jpg"

    private static let alertDefaultsKey = "latest-alert"
    private static let alertImageFileName = "latest-alert.jpg"

    private static let recentAlertsKey = "recent-alerts"
    private static let recentHeroFileName = "recent-hero.jpg"

    static func save(imageData: Data, camera: String, serverName: String) {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ApexAppGroup.identifier) else {
            return
        }

        let imageURL = containerURL.appendingPathComponent(imageFileName)
        do {
            try imageData.write(to: imageURL, options: [.atomic])
            let snapshot = SharedCameraSnapshot(
                camera: camera,
                serverName: serverName,
                capturedAt: Date(),
                imageFileName: imageFileName
            )
            let encoded = try JSONEncoder().encode(snapshot)
            UserDefaults(suiteName: ApexAppGroup.identifier)?.set(encoded, forKey: defaultsKey)
        } catch {
            UserDefaults(suiteName: ApexAppGroup.identifier)?.removeObject(forKey: defaultsKey)
        }
    }

    static func load() -> (snapshot: SharedCameraSnapshot, imageURL: URL)? {
        guard
            let data = UserDefaults(suiteName: ApexAppGroup.identifier)?.data(forKey: defaultsKey),
            let snapshot = try? JSONDecoder().decode(SharedCameraSnapshot.self, from: data),
            let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ApexAppGroup.identifier)
        else {
            return nil
        }

        return (snapshot, containerURL.appendingPathComponent(snapshot.imageFileName))
    }

    static func saveLatestAlert(label: String, subLabel: String?, camera: String, severity: String, when: Date, imageData: Data?) {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ApexAppGroup.identifier) else {
            return
        }

        var savedImageFileName: String? = nil
        if let imageData {
            let imageURL = containerURL.appendingPathComponent(alertImageFileName)
            do {
                try imageData.write(to: imageURL, options: [.atomic])
                savedImageFileName = alertImageFileName
            } catch {
                savedImageFileName = nil
            }
        }

        let alert = SharedAlert(
            label: label,
            subLabel: subLabel,
            camera: camera,
            severity: severity,
            when: when,
            imageFileName: savedImageFileName
        )

        do {
            let encoded = try JSONEncoder().encode(alert)
            UserDefaults(suiteName: ApexAppGroup.identifier)?.set(encoded, forKey: alertDefaultsKey)
        } catch {
            UserDefaults(suiteName: ApexAppGroup.identifier)?.removeObject(forKey: alertDefaultsKey)
        }
    }

    static func loadLatestAlert() -> (alert: SharedAlert, imageURL: URL?)? {
        guard
            let data = UserDefaults(suiteName: ApexAppGroup.identifier)?.data(forKey: alertDefaultsKey),
            let alert = try? JSONDecoder().decode(SharedAlert.self, from: data)
        else {
            return nil
        }

        guard
            let imageFileName = alert.imageFileName,
            let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ApexAppGroup.identifier)
        else {
            return (alert, nil)
        }

        return (alert, containerURL.appendingPathComponent(imageFileName))
    }

    // MARK: - Recent activity feed (for the widget)

    /// Persists a short list of the most recent alerts plus a single hero image (the
    /// newest event's snapshot). The widget renders the list as a recent-activity feed
    /// and uses the hero as its large image — no live streaming in the widget.
    static func saveRecentAlerts(_ alerts: [SharedAlert], heroImageData: Data?) {
        let defaults = UserDefaults(suiteName: ApexAppGroup.identifier)

        // Alerts BEFORE the hero image — `loadRecentAlerts` below reads them in that same order,
        // so a widget timeline reload landing between these two writes sees the NEW captions next
        // to the (briefly) OLD photo, rather than an old caption suddenly paired with a brand-new
        // unrelated photo. Either ordering has a race (two separate storage backends, no shared
        // transaction) — this one just fails in the less confusing direction.
        if let encoded = try? JSONEncoder().encode(Array(alerts.prefix(8))) {
            defaults?.set(encoded, forKey: recentAlertsKey)
        }

        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ApexAppGroup.identifier) {
            let heroURL = containerURL.appendingPathComponent(recentHeroFileName)
            if let heroImageData {
                try? heroImageData.write(to: heroURL, options: [.atomic])
            } else {
                // No fresh hero (thumbnail fetch failed, or "all clear") — delete the stale one so
                // the widget never shows an old snapshot under a newer caption or an empty feed.
                try? FileManager.default.removeItem(at: heroURL)
            }
        }
    }

    static func loadRecentAlerts() -> (alerts: [SharedAlert], heroImageURL: URL?) {
        let defaults = UserDefaults(suiteName: ApexAppGroup.identifier)
        let alerts: [SharedAlert]
        if let data = defaults?.data(forKey: recentAlertsKey),
           let decoded = try? JSONDecoder().decode([SharedAlert].self, from: data) {
            alerts = decoded
        } else {
            alerts = []
        }

        var heroURL: URL?
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ApexAppGroup.identifier) {
            let candidate = containerURL.appendingPathComponent(recentHeroFileName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                heroURL = candidate
            }
        }
        return (alerts, heroURL)
    }

    // MARK: - Camera catalog (names, for Siri / Watch / CarPlay pickers)

    private static let cameraNamesKey = "apex.cameraNames"

    static func saveCameraNames(_ names: [String]) {
        UserDefaults(suiteName: ApexAppGroup.identifier)?.set(names, forKey: cameraNamesKey)
    }

    static func loadCameraNames() -> [String] {
        UserDefaults(suiteName: ApexAppGroup.identifier)?.stringArray(forKey: cameraNamesKey) ?? []
    }
}
