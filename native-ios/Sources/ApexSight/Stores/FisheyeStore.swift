import Foundation

/// Persists which cameras the user marked as fisheye, plus each one's lens
/// calibration, in the app group — same pattern as CameraGroupStore.
@MainActor
final class FisheyeStore: ObservableObject {
    /// One shared instance — the live viewer, calibration sheet, and Settings all
    /// observe the same configs so a toggle/slider anywhere updates everywhere.
    static let shared = FisheyeStore()

    @Published private(set) var configs: [String: FisheyeConfig] = [:]

    private let key = "apex.fisheyeCameras"
    private var defaults: UserDefaults? { UserDefaults(suiteName: ApexAppGroup.identifier) }

    init() {
        load()
    }

    func isFisheye(_ camera: String) -> Bool {
        configs[camera] != nil
    }

    func config(for camera: String) -> FisheyeConfig {
        configs[camera] ?? FisheyeConfig()
    }

    func setFisheye(_ camera: String, enabled: Bool) {
        if enabled {
            guard configs[camera] == nil else { return }
            configs[camera] = FisheyeConfig()
        } else {
            configs[camera] = nil
        }
        save()
    }

    func update(_ camera: String, config: FisheyeConfig) {
        guard configs[camera] != nil else { return }
        configs[camera] = config
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        defaults?.set(data, forKey: key)
    }

    private func load() {
        guard let data = defaults?.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: FisheyeConfig].self, from: data) else { return }
        configs = decoded
    }
}
