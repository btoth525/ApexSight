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

struct SharedAlert: Codable, Hashable {
    let label: String        // e.g. "person", "car"
    let subLabel: String?    // e.g. a recognized face/plate, may be nil
    let camera: String
    let severity: String     // "alert" or "detection"
    let when: Date
    let imageFileName: String?  // nil when no thumbnail was cached
}

enum SharedSnapshotStore {
    private static let defaultsKey = "latest-camera-snapshot"
    private static let imageFileName = "latest-camera.jpg"

    private static let alertDefaultsKey = "latest-alert"
    private static let alertImageFileName = "latest-alert.jpg"

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
}
