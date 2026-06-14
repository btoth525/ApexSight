import Foundation

enum NotificationCopy {
    static func title(for event: FrigateEvent) -> String {
        "\(emoji(for: event.label, subLabel: event.subLabel)) \(titleize(event.displayLabel)) detected"
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
        let subLabels = review.data?.subLabels ?? []
        if objects.isEmpty {
            return "📹 Camera activity"
        }
        let firstSub = subLabels.first
        let firstObj = objects.first ?? ""
        let e = emoji(for: firstObj, subLabel: firstSub)
        let names = objects.map { titleize($0) }.joined(separator: ", ")
        return "\(e) \(names)"
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

    static func emoji(for label: String, subLabel: String? = nil) -> String {
        if let sub = subLabel, !sub.isEmpty {
            let subEmoji = subLabelEmoji(sub)
            if subEmoji != "📹" { return subEmoji }
        }
        return labelEmoji(label)
    }

    private static func subLabelEmoji(_ sub: String) -> String {
        switch sub.lowercased() {
        case "amazon": return "📦"
        case "ups": return "📦"
        case "fedex": return "📦"
        case "usps": return "📬"
        case "dhl": return "📦"
        case "face": return "👤"
        case "child": return "🧒"
        case "elderly": return "👴"
        case "vest": return "🦺"
        case "license_plate", "license plate": return "🔎"
        case "police": return "🚔"
        case "fire_truck", "fire truck": return "🚒"
        case "ambulance": return "🚑"
        default: return "📹"
        }
    }

    private static func labelEmoji(_ label: String) -> String {
        switch label.lowercased() {
        case "person": return "🧍"
        case "car": return "🚗"
        case "truck": return "🚚"
        case "bus": return "🚌"
        case "motorcycle": return "🏍"
        case "bicycle": return "🚲"
        case "dog": return "🐕"
        case "cat": return "🐈"
        case "package": return "📦"
        case "bird": return "🐦"
        case "bear": return "🐻"
        case "deer": return "🦌"
        case "fire": return "🔥"
        case "smoke": return "💨"
        case "license_plate", "license plate": return "🔎"
        case "face": return "👤"
        default: return "📹"
        }
    }
}
