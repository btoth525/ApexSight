import Foundation

/// A "this phone's iOS Focus is muting camera alerts" switch — deliberately SEPARATE from
/// `GlobalSnooze`.
///
/// `GlobalSnooze` is household state: it rides `/v1/gate`, and the relay applies it to every phone
/// on the pairing code at once. That's correct for a deliberate "snooze the house for an hour"
/// action, and wrong for a Focus. A Focus (Do Not Disturb, Sleep, Driving…) is a property of ONE
/// person's phone — routing it through the household gate meant one partner turning on Do Not
/// Disturb silenced everyone's cameras for eight hours, with nothing on screen saying why.
///
/// So the Focus filter writes here instead, and this value is mirrored only into THIS device's
/// prefs (`focus_snoozed_until` via `/v1/device-prefs`), which the relay evaluates per device.
enum FocusSnooze {
    private static let key = "apex.focusSnoozeUntil"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: ApexAppGroup.identifier)
    }

    /// When this device's Focus mute lifts, or nil if not currently muted (expired reads as nil).
    static var until: Date? {
        guard let stamp = defaults?.double(forKey: key), stamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: stamp)
        return date > Date() ? date : nil
    }

    static var isActive: Bool { until != nil }

    /// Epoch seconds for syncing to the relay; 0 when not muted (so an expired value clears the
    /// stored pref rather than lingering).
    static var epochForSync: Double { until?.timeIntervalSince1970 ?? 0 }

    static func mute(until date: Date) {
        defaults?.set(date.timeIntervalSince1970, forKey: key)
        ApexSurfaceRefresh.reload()
    }

    static func clear() {
        defaults?.removeObject(forKey: key)
        ApexSurfaceRefresh.reload()
    }
}
