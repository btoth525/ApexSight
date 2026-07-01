import Foundation

/// Persists on-device AI analysis per event so it survives closing/reopening the app — the work
/// runs once, then reappears instantly. Keyed by event id. Small text values, kept in a bounded
/// LRU-ish map in standard UserDefaults (no images, no secrets).
enum AIAnalysisStore {
    private static let indexKey = "ai.analysis.index"   // ordered list of stored event ids
    private static let maxEntries = 300
    private static func valueKey(_ id: String) -> String { "ai.analysis.v.\(id)" }

    private static var defaults: UserDefaults { .standard }

    static func load(_ eventID: String) -> String? {
        let v = defaults.string(forKey: valueKey(eventID))
        return (v?.isEmpty == false) ? v : nil
    }

    static func save(_ eventID: String, _ text: String) {
        guard !text.isEmpty else { return }
        defaults.set(text, forKey: valueKey(eventID))

        // Maintain a bounded index so this never grows unbounded.
        var index = defaults.stringArray(forKey: indexKey) ?? []
        index.removeAll { $0 == eventID }
        index.append(eventID)
        while index.count > maxEntries {
            let evicted = index.removeFirst()
            defaults.removeObject(forKey: valueKey(evicted))
        }
        defaults.set(index, forKey: indexKey)
    }
}
