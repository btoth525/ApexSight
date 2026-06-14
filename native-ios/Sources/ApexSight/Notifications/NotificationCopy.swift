import Foundation

enum NotificationCopy {
    static func title(for event: FrigateEvent) -> String {
        "\(emoji(for: event.label)) \(titleize(event.label)) detected"
    }

    static func body(for event: FrigateEvent) -> String {
        var parts = [titleize(event.camera)]
        if let score = event.score ?? event.topScore {
            parts.append("\(Int(score * 100))% confidence")
        }
        if let zones = event.zones, !zones.isEmpty {
            parts.append("Zone: \(zones.map(titleize).joined(separator: ", "))")
        }
        return parts.joined(separator: " • ")
    }

    static func title(for review: FrigateReviewItem) -> String {
        let objects = review.data?.objects ?? []
        if objects.isEmpty {
            return "📹 Camera activity"
        }
        return "\(objects.map(emoji).joined()) \(objects.map(titleize).joined(separator: ", "))"
    }

    static func body(for review: FrigateReviewItem) -> String {
        var parts = [titleize(review.camera)]
        if let severity = review.severity {
            parts.append(titleize(severity))
        }
        if let zones = review.data?.zones, !zones.isEmpty {
            parts.append("Zone: \(zones.map(titleize).joined(separator: ", "))")
        }
        return parts.joined(separator: " • ")
    }

    static func emoji(for label: String) -> String {
        switch label.lowercased() {
        case "person": return "🧍"
        case "car": return "🚗"
        case "truck": return "🚚"
        case "bus": return "🚌"
        case "motorcycle": return "🏍"
        case "bicycle": return "🚲"
        case "dog": return "🐕"
        case "cat": return "🐈"
        case "package", "amazon", "fedex", "ups": return "📦"
        case "license_plate": return "🔎"
        default: return "📹"
        }
    }
}
