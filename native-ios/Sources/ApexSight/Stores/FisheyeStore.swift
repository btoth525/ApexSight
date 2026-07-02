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

    /// Persist where the user left a view aimed. `pane` nil = the single dewarped view
    /// (shared by the viewer and the wall tile); 0–3 = a quad-view pane.
    func savePose(_ camera: String, pane: Int?, pose: FisheyePose) {
        guard var config = configs[camera] else { return }
        if let pane {
            var poses = config.quadPoses ?? (0..<4).map(FisheyePose.quadDefault)
            guard pane >= 0, pane < poses.count else { return }
            poses[pane] = pose
            config.quadPoses = poses
        } else {
            config.pose = pose
        }
        configs[camera] = config
        save()
    }

    func pose(for camera: String, pane: Int?) -> FisheyePose {
        let config = configs[camera] ?? FisheyeConfig()
        if let pane {
            let poses = config.quadPoses ?? (0..<4).map(FisheyePose.quadDefault)
            return pane < poses.count ? poses[pane] : FisheyePose.quadDefault(pane)
        }
        return config.pose ?? FisheyePose()
    }

    func setLocked(_ camera: String, locked: Bool) {
        guard var config = configs[camera] else { return }
        config.locked = locked
        configs[camera] = config
        save()
    }

    func setQuadEnabled(_ camera: String, enabled: Bool) {
        guard var config = configs[camera] else { return }
        config.quadEnabled = enabled
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
