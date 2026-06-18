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

        if let heroImageData,
           let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ApexAppGroup.identifier) {
            let heroURL = containerURL.appendingPathComponent(recentHeroFileName)
            try? heroImageData.write(to: heroURL, options: [.atomic])
        }

        if let encoded = try? JSONEncoder().encode(Array(alerts.prefix(8))) {
            defaults?.set(encoded, forKey: recentAlertsKey)
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

    // MARK: - Incident Live Activity snapshot

    /// All incident snapshot files share this prefix so we can sweep stale ones when a new
    /// incident starts — each incident gets a unique filename (so the Live Activity never
    /// caches a previous incident's image against an identical URL).
    private static let incidentImagePrefix = "incident-"

    /// Caches the detection image for the current incident's Live Activity and returns the
    /// app-group-relative filename to embed in the ContentState. Clears any prior incident
    /// images first so the shared container holds only the live one.
    @discardableResult
    static func saveIncidentSnapshot(_ imageData: Data, token: String) -> String? {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ApexAppGroup.identifier) else {
            return nil
        }
        clearIncidentSnapshots()
        let safeToken = token.isEmpty ? UUID().uuidString : token
        let name = "\(incidentImagePrefix)\(safeToken).jpg"
        let imageURL = containerURL.appendingPathComponent(name)
        do {
            try imageData.write(to: imageURL, options: [.atomic])
            return name
        } catch {
            return nil
        }
    }

    /// Resolves an incident snapshot filename (from the ContentState) to its file URL in
    /// the shared container, or nil if the file is missing.
    static func incidentSnapshotURL(named name: String) -> URL? {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ApexAppGroup.identifier) else {
            return nil
        }
        let url = containerURL.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Removes all cached incident snapshots — called when an incident ends/dismisses and
    /// before a new one is saved.
    static func clearIncidentSnapshots() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ApexAppGroup.identifier) else {
            return
        }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: containerURL.path) else { return }
        for file in files where file.hasPrefix(incidentImagePrefix) {
            try? fm.removeItem(at: containerURL.appendingPathComponent(file))
        }
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
