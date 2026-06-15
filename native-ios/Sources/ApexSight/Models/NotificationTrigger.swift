import Foundation

struct NotificationTrigger: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var cameras: [String] = []          // empty = all cameras
    var labels: [String] = []           // empty = all labels
    var requiredZones: [String] = []    // empty = any zone; all must match if set
    var minConfidence: Double = 0.0     // 0 = any confidence
    var respectQuietHours: Bool = true
    var enabled: Bool = true

    func matches(camera: String, label: String, zones: [String], score: Double) -> Bool {
        guard enabled else { return false }
        if !cameras.isEmpty, !cameras.contains(camera) { return false }
        if !labels.isEmpty, !labels.contains(label) { return false }
        if !requiredZones.isEmpty {
            let allMatch = requiredZones.allSatisfy { zones.contains($0) }
            guard allMatch else { return false }
        }
        if score < minConfidence { return false }
        return true
    }
}
