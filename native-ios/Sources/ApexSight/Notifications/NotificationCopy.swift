import Foundation

enum NotificationCopy {
    static func title(for event: FrigateEvent) -> String {
        "\(emoji(for: event.label, subLabel: event.subLabel)) \(titleize(event.displayLabel)) detected"
    }

    static func body(for event: FrigateEvent) -> String {
        var parts = [titleize(event.camera)]
        if let plate = event.recognizedLicensePlate, !plate.isEmpty {
            parts.append("Plate \(plate.uppercased())")
        } else if let face = event.recognizedFace {
            parts.append(titleize(face))
        } else if let score = event.score ?? event.topScore {
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
        if objects.isEmpty { return "📹 Camera activity" }
        let firstSub = subLabels.first
        let firstObj = objects.first ?? ""
        let e = emoji(for: firstObj, subLabel: firstSub)
        // Prefer sub-label name when it adds meaning (face, plate, carrier)
        if let sub = firstSub, !sub.isEmpty {
            return "\(e) \(titleize(sub))"
        }
        return "\(e) \(objects.map { titleize($0) }.joined(separator: ", "))"
    }

    /// Review-row/detail title that keeps BOTH the object and its sub-label for
    /// context — "Person — Alex", "Car — 7XYZ123", "Package — Amazon" — instead of
    /// dropping the object the way the notification `title` does. Falls back to the
    /// object list when there's no sub-label.
    static func combinedTitle(for review: FrigateReviewItem) -> String {
        let objects = review.data?.objects ?? []
        guard !objects.isEmpty else { return "📹 Camera activity" }
        let firstObj = objects.first ?? ""
        let firstSub = (review.data?.subLabels ?? []).first { !$0.isEmpty }
        let e = emoji(for: firstObj, subLabel: firstSub)
        if let sub = firstSub {
            return "\(e) \(titleize(firstObj)) — \(titleize(sub))"
        }
        return "\(e) \(objects.map { titleize($0) }.joined(separator: ", "))"
    }

    static func body(for review: FrigateReviewItem) -> String {
        var parts = [titleize(review.camera)]
        let subs = (review.data?.subLabels ?? []).filter { !$0.isEmpty }
        if !subs.isEmpty {
            parts.append(subs.map { titleize($0) }.joined(separator: ", "))
        }
        if let zones = review.data?.zones, !zones.isEmpty {
            parts.append("Zone: \(zones.map(titleize).joined(separator: ", "))")
        }
        return parts.joined(separator: " • ")
    }

    static func aiBody(for review: FrigateReviewItem) -> String? {
        guard let desc = review.description, !desc.isEmpty else { return nil }
        let firstSentence = desc.components(separatedBy: ".").first ?? desc
        let trimmed = firstSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(120))
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
        // Delivery carriers
        case "amazon": return "📦"
        case "ups": return "📦"
        case "fedex": return "📦"
        case "usps": return "📬"
        case "dhl": return "📦"
        case "an_post": return "📮"
        case "purolator": return "📦"
        case "postnl": return "📦"
        case "postnord": return "📦"
        case "gls": return "📦"
        case "dpd": return "📦"
        case "canada_post": return "📮"
        case "royal_mail": return "📮"
        // People/face
        case "face": return "👤"
        case "child": return "🧒"
        case "elderly": return "👴"
        case "vest": return "🦺"
        // Animals
        case "dog": return "🐕"
        case "cat": return "🐈"
        case "bird": return "🐦"
        case "deer": return "🦌"
        case "horse": return "🐴"
        case "bear": return "🐻"
        case "raccoon": return "🦝"
        case "fox": return "🦊"
        case "cow": return "🐄"
        case "squirrel": return "🐿️"
        case "goat": return "🐐"
        case "rabbit": return "🐇"
        case "kangaroo": return "🦘"
        case "skunk": return "🦨"
        // Vehicles/plates
        case "license_plate", "license plate": return "🔎"
        case "motorcycle": return "🏍"
        // Other
        case "package": return "📦"
        case "waste_bin": return "🗑️"
        case "bbq_grill": return "🍖"
        case "robot_lawnmower": return "🤖"
        case "umbrella": return "☂️"
        case "police": return "🚔"
        // Emergency
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
