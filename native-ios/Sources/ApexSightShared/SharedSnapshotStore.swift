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

enum SharedSnapshotStore {
    private static let defaultsKey = "latest-camera-snapshot"
    private static let imageFileName = "latest-camera.jpg"

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
}
