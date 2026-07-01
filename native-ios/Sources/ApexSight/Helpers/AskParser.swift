import Foundation

// MARK: - On-device question parser
//
// Turns a free-text question ("how many packages today", "when was the dog out")
// into a structured plan of Frigate filters plus a natural-language answer. Runs
// entirely on-device — no model, no network beyond the events query it informs.

struct AskPlan {
    var label: String?
    var subLabel: String?          // e.g. a carrier (amazon/ups) — Frigate stores these as sub_labels
    var camera: String?
    var after: Date?
    var before: Date?
    var unknownOnly = false
    var personName: String?
    var wantsLatest = false
    var subjectSingular = "event"
    var subjectPlural = "events"
    var rangeLabel = "today"

    func matches(_ e: FrigateEvent) -> Bool {
        if unknownOnly, !(e.subLabel?.isEmpty ?? true) { return false }
        if let name = personName {
            guard let face = e.recognizedFace, face.caseInsensitiveCompare(name) == .orderedSame else { return false }
        }
        if let subLabel {
            guard (e.subLabel ?? "").localizedCaseInsensitiveContains(subLabel) else { return false }
        }
        return true
    }
}

enum AskParser {
    private static let labelMap: [(keys: [String], label: String, singular: String, plural: String)] = [
        (["package", "delivery", "deliveries", "amazon", "ups", "fedex", "usps", "mail"], "package", "package", "packages"),
        (["person", "people", "someone", "somebody", "anyone", "intruder", "stranger",
          "kid", "kids", "child", "children", "toddler", "baby", "boy", "girl",
          "man", "woman", "guy", "lady"], "person", "person", "people"),
        (["car", "vehicle", "vehicles", "automobile", "sedan", "suv"], "car", "car", "cars"),
        (["truck", "van", "pickup"], "truck", "truck", "trucks"),
        (["dog", "pet", "puppy"], "dog", "dog", "dogs"),
        (["cat", "kitten"], "cat", "cat", "cats"),
        (["bike", "bicycle", "cyclist"], "bicycle", "bike", "bikes"),
        (["bird"], "bird", "bird", "birds"),
        (["motorcycle", "motorbike", "scooter"], "motorcycle", "motorcycle", "motorcycles"),
    ]

    /// Every Frigate object label implied by a free-text query — e.g. "kid on a bike"
    /// → ["person", "bicycle"]. Unlike `interpret`, this does NOT stop at the first
    /// match, so multi-object descriptions surface all relevant detections.
    static func impliedLabels(in q: String) -> [String] {
        let text = q.lowercased()
        var labels: [String] = []
        for entry in labelMap where entry.keys.contains(where: { text.contains($0) }) {
            if !labels.contains(entry.label) { labels.append(entry.label) }
        }
        return labels
    }

    static func interpret(_ q: String, cameras: [String], faceNames: [String]) -> AskPlan {
        let text = q.lowercased()
        var plan = AskPlan()

        // Delivery carriers ride on Frigate SUB-LABELS (amazon/ups/fedex on the delivery person or
        // truck), NOT the 'package' label — which often has zero events. So match sub_label and
        // leave the object label open, or "any amazon today" finds nothing.
        let carriers = ["amazon", "ups", "fedex", "usps", "dhl", "ontrac", "lasership"]
        if let carrier = carriers.first(where: { text.contains($0) }) {
            plan.subLabel = carrier
            plan.subjectSingular = "\(carrier.uppercased()) delivery"
            plan.subjectPlural = "\(carrier.uppercased()) deliveries"
        } else {
            // Object
            for entry in labelMap where entry.keys.contains(where: { text.contains($0) }) {
                plan.label = entry.label
                plan.subjectSingular = entry.singular
                plan.subjectPlural = entry.plural
                break
            }
        }

        // Camera (match the camera's words against the question)
        for camera in cameras {
            let words = camera.replacingOccurrences(of: "_", with: " ").lowercased()
            if text.contains(words) || words.split(separator: " ").allSatisfy({ text.contains($0) && $0.count > 2 }) {
                plan.camera = camera
                break
            }
        }

        // Unknown people
        if text.contains("unknown") || text.contains("stranger") || text.contains("unrecognized") {
            plan.unknownOnly = true
            if plan.label == nil { plan.label = "person"; plan.subjectSingular = "unknown person"; plan.subjectPlural = "unknown people" }
        }

        // Known face by name
        for name in faceNames where text.contains(name.lowercased()) {
            plan.personName = name
        }

        // "last / when did ... last"
        if text.contains("last") || text.contains("when ") || text.hasPrefix("when") {
            plan.wantsLatest = true
        }

        // Time range
        let cal = Calendar.current
        let now = Date()
        if text.contains("yesterday") {
            let startToday = cal.startOfDay(for: now)
            plan.after = cal.date(byAdding: .day, value: -1, to: startToday)
            plan.before = startToday
            plan.rangeLabel = "yesterday"
        } else if text.contains("this week") || text.contains("past week") || text.contains(" week") {
            plan.after = cal.date(byAdding: .day, value: -7, to: now)
            plan.rangeLabel = "this week"
        } else if text.contains("this month") || text.contains("past month") || text.contains(" month") {
            plan.after = cal.date(byAdding: .day, value: -30, to: now)
            plan.rangeLabel = "this month"
        } else if text.contains("hour") {
            plan.after = cal.date(byAdding: .hour, value: -1, to: now)
            plan.rangeLabel = "in the last hour"
        } else if text.contains("tonight") || text.contains("last night") {
            plan.after = cal.date(byAdding: .hour, value: -12, to: now)
            plan.rangeLabel = "tonight"
        } else {
            // Default: today
            plan.after = cal.startOfDay(for: now)
            plan.rangeLabel = "today"
        }
        return plan
    }

    static func answer(for plan: AskPlan, results: [FrigateEvent]) -> String {
        let subject = plan.subjectPlural
        let single = plan.subjectSingular
        guard let latest = results.first else {
            return "No \(subject) \(plan.rangeLabel)."
        }
        let count = results.count
        let camera = titleize(latest.camera)
        let when = relativeString(Date(timeIntervalSince1970: latest.startTime ?? 0))

        if plan.wantsLatest {
            return "The last \(single) was at \(camera), \(when)."
        }
        let noun = count == 1 ? single : subject
        return "Yes — \(count) \(noun) \(plan.rangeLabel). Most recent at \(camera), \(when)."
    }

    private static func relativeString(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}
