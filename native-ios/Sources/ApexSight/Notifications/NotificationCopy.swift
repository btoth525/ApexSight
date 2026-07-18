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

    /// Frigate suffixes an object type with `-verified` once it's matched to a sub-label (e.g.
    /// "car-verified"); strip it for DISPLAY/emoji lookup only. Never applied to the model's raw
    /// `objects` values used elsewhere for trigger/mute matching (see `AppState.handleReview`).
    private static func displayObject(_ raw: String) -> String {
        raw.hasSuffix("-verified") ? String(raw.dropLast("-verified".count)) : raw
    }

    /// Attribute a sub-label to one specific object type only when it's unambiguous: either the
    /// review has just one distinct object type, or `verified_objects` narrows it to exactly one.
    /// `objects` and `sub_labels` are independently deduplicated lists — `objects.first` is NOT
    /// necessarily the object `subLabels.first` belongs to (confirmed live: a person + a
    /// verified car whose sub-label was a truck's name rendered "Person — Brandons Truck").
    private static func attributableObject(for review: FrigateReviewItem) -> String? {
        let objects = Set((review.data?.objects ?? []).map(displayObject))
        if objects.count == 1 { return objects.first }
        let verified = Set((review.data?.verifiedObjects ?? []).map(displayObject))
        return verified.count == 1 ? verified.first : nil
    }

    static func title(for review: FrigateReviewItem) -> String {
        let objects = (review.data?.objects ?? []).map(displayObject)
        guard !objects.isEmpty else { return "📹 Camera activity" }
        let subLabels = (review.data?.subLabels ?? []).filter { !$0.isEmpty }
        // Prefer sub-label name when it can be confidently attributed to an object.
        if let obj = attributableObject(for: review), let sub = subLabels.first {
            return "\(emoji(for: obj, subLabel: sub)) \(titleize(sub))"
        }
        let e = emoji(for: objects.first ?? "", subLabel: subLabels.first)
        let objectList = Array(Set(objects)).sorted().map { titleize($0) }.joined(separator: ", ")
        guard !subLabels.isEmpty else { return "\(e) \(objectList)" }
        return "\(e) \(objectList) — \(subLabels.map { titleize($0) }.joined(separator: ", "))"
    }

    /// Review-row/detail title that keeps BOTH the object and its sub-label for
    /// context — "Person — Alex", "Car — 7XYZ123", "Package — Amazon" — instead of
    /// dropping the object the way the notification `title` does. Falls back to the
    /// object list when there's no sub-label.
    static func combinedTitle(for review: FrigateReviewItem) -> String {
        let objects = (review.data?.objects ?? []).map(displayObject)
        guard !objects.isEmpty else { return "📹 Camera activity" }
        let subLabels = (review.data?.subLabels ?? []).filter { !$0.isEmpty }
        if let obj = attributableObject(for: review), let sub = subLabels.first {
            return "\(emoji(for: obj, subLabel: sub)) \(titleize(obj)) — \(titleize(sub))"
        }
        let e = emoji(for: objects.first ?? "", subLabel: subLabels.first)
        let objectList = Array(Set(objects)).sorted().map { titleize($0) }.joined(separator: ", ")
        guard !subLabels.isEmpty else { return "\(e) \(objectList)" }
        return "\(e) \(objectList) — \(subLabels.map { titleize($0) }.joined(separator: ", "))"
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
