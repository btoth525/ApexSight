import Foundation

/// Tracks which review IDs have already produced a notification, persisted in the
/// app group so the main app, background refresh, and relaunches all agree.
/// This is the authoritative dedupe across the real-time and background paths
/// (the in-memory cooldown map in NotificationPreferencesStore does not survive launches).
enum LastSeenStore {
    private static let idsKey = "apex.lastSeenReviewIDs"
    private static let timestampKey = "apex.lastSeenTimestamp"
    private static let maxRetained = 100

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: ApexAppGroup.identifier)
    }

    static var lastSeenReviewIDs: [String] {
        defaults?.stringArray(forKey: idsKey) ?? []
    }

    static var lastSeenTimestamp: Double {
        defaults?.double(forKey: timestampKey) ?? 0
    }

    static func isNew(_ id: String) -> Bool {
        !lastSeenReviewIDs.contains(id)
    }

    static func markSeen(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        var retained = lastSeenReviewIDs
        for id in ids where !retained.contains(id) {
            retained.append(id)
        }
        if retained.count > maxRetained {
            retained = Array(retained.suffix(maxRetained))
        }
        defaults?.set(retained, forKey: idsKey)
        defaults?.set(Date().timeIntervalSince1970, forKey: timestampKey)
    }
}
