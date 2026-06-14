import Foundation
import UserNotifications

struct NotificationPreferences: Codable {
    var cameraEnabled: [String: Bool] = [:]
    var objectEnabled: [String: Bool] = [:]
    var zoneEnabled: [String: Bool] = [:]
    var quietHoursEnabled: Bool = false
    var quietHoursStartHour: Int = 22
    var quietHoursStartMinute: Int = 0
    var quietHoursEndHour: Int = 7
    var quietHoursEndMinute: Int = 0
    var cooldownSeconds: [String: Int] = [:]

    func isCameraEnabled(_ name: String) -> Bool {
        cameraEnabled[name] ?? true
    }

    func isObjectEnabled(_ label: String) -> Bool {
        objectEnabled[label] ?? true
    }

    func isZoneEnabled(_ zone: String) -> Bool {
        zoneEnabled[zone] ?? true
    }

    func cooldown(for camera: String) -> Int {
        cooldownSeconds[camera] ?? 30
    }

    func isQuietNow() -> Bool {
        guard quietHoursEnabled else { return false }
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let currentMinutes = (now.hour ?? 0) * 60 + (now.minute ?? 0)
        let startMinutes = quietHoursStartHour * 60 + quietHoursStartMinute
        let endMinutes = quietHoursEndHour * 60 + quietHoursEndMinute

        if startMinutes <= endMinutes {
            return currentMinutes >= startMinutes && currentMinutes < endMinutes
        } else {
            return currentMinutes >= startMinutes || currentMinutes < endMinutes
        }
    }
}

@MainActor
final class NotificationPreferencesStore: ObservableObject {
    @Published var preferences = NotificationPreferences()

    private let key = "com.brandontoth.apexsight.notificationPreferences"
    private var lastNotificationTime: [String: Date] = [:]

    init() {
        load()
    }

    func save() {
        if let data = try? JSONEncoder().encode(preferences) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let prefs = try? JSONDecoder().decode(NotificationPreferences.self, from: data) else { return }
        preferences = prefs
    }

    func shouldDeliver(camera: String, label: String, zones: [String]) -> Bool {
        guard preferences.isCameraEnabled(camera) else { return false }
        guard preferences.isObjectEnabled(label) else { return false }
        if !zones.isEmpty {
            let anyZoneEnabled = zones.contains { preferences.isZoneEnabled($0) }
            guard anyZoneEnabled else { return false }
        }
        guard !preferences.isQuietNow() else { return false }

        let cooldown = TimeInterval(preferences.cooldown(for: camera))
        if let last = lastNotificationTime[camera], Date().timeIntervalSince(last) < cooldown {
            return false
        }
        lastNotificationTime[camera] = Date()
        return true
    }
}
