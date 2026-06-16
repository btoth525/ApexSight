import Foundation

/// A single "mute every camera alert until <time>" switch, stored in the app group so
/// it's shared across the app, the background refresh task, and Siri/App Intents
/// (which can run in a separate process). Used by the notification delivery gate.
enum GlobalSnooze {
    private static let key = "apex.snoozeAllUntil"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: ApexAppGroup.identifier)
    }

    /// The time alerts resume, or nil if not currently snoozed (expired snoozes read as nil).
    static var until: Date? {
        guard let stamp = defaults?.double(forKey: key), stamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: stamp)
        return date > Date() ? date : nil
    }

    static var isActive: Bool { until != nil }

    static func snooze(until date: Date) {
        defaults?.set(date.timeIntervalSince1970, forKey: key)
        ApexSurfaceRefresh.reload()
    }

    static func clear() {
        defaults?.removeObject(forKey: key)
        ApexSurfaceRefresh.reload()
    }
}
