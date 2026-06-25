import Foundation

/// A summary of a day's camera activity, built from Frigate events.
struct DailyRecap {
    var total = 0
    var cameraCounts: [(camera: String, count: Int)] = []
    var labelCounts: [(label: String, count: Int)] = []
    var people: [String] = []
    var packages = 0
    var firstAt: Date?
    var lastAt: Date?
    /// Hour (0–23) with the most activity, for the "busiest time" highlight.
    var busiestHour: Int?
    /// Delivery carriers seen today (sub-label → count): Amazon, UPS, FedEx…
    var carriers: [(name: String, count: Int)] = []

    var isEmpty: Bool { total == 0 }

    /// e.g. "2–3 PM" for the busiest hour.
    var busiestHourLabel: String? {
        guard let h = busiestHour else { return nil }
        func fmt(_ hour: Int) -> String {
            let h12 = hour % 12 == 0 ? 12 : hour % 12
            return "\(h12)\(hour < 12 ? "AM" : "PM")"
        }
        return "\(fmt(h))–\(fmt((h + 1) % 24))"
    }

    var headline: String {
        guard !isEmpty else { return "All quiet today" }
        let cams = cameraCounts.count
        return "\(total) event\(total == 1 ? "" : "s") across \(cams) camera\(cams == 1 ? "" : "s")"
    }

    /// One-liner for the notification body.
    var notificationBody: String {
        guard !isEmpty else { return "No camera activity today." }
        var bits: [String] = []
        if !people.isEmpty { bits.append("Seen: " + people.prefix(3).map(titleize).joined(separator: ", ")) }
        if let top = cameraCounts.first { bits.append("Busiest: \(titleize(top.camera)) (\(top.count))") }
        if packages > 0 { bits.append("\(packages) 📦") }
        return bits.joined(separator: " · ")
    }
}

enum RecapBuilder {
    /// Fetches today's events (since local midnight).
    static func fetchToday(client: FrigateClient) async -> [FrigateEvent] {
        let start = Calendar.current.startOfDay(for: Date())
        return (try? await client.events(after: start, before: Date(), limit: 500)) ?? []
    }

    static func build(events: [FrigateEvent], style: NotificationStyle) -> DailyRecap {
        var recap = DailyRecap()
        recap.total = events.count
        guard !events.isEmpty else { return recap }

        let carrierKeys: Set<String> = [
            "amazon", "ups", "usps", "fedex", "dhl", "an_post", "purolator",
            "dpd", "gls", "postnl", "postnord", "canada_post", "royal_mail"
        ]
        var cameras: [String: Int] = [:]
        var labels: [String: Int] = [:]
        var carriers: [String: Int] = [:]
        var hours: [Int: Int] = [:]
        var people = Set<String>()
        let cal = Calendar.current
        for event in events {
            cameras[event.camera, default: 0] += 1
            labels[event.label, default: 0] += 1
            if let face = event.recognizedFace { people.insert(face) }
            if event.label.lowercased() == "package" { recap.packages += 1 }
            if let sub = event.subLabel?.lowercased(), carrierKeys.contains(sub) {
                carriers[sub, default: 0] += 1
            }
            if let start = event.startTime {
                let hour = cal.component(.hour, from: Date(timeIntervalSince1970: start))
                hours[hour, default: 0] += 1
            }
        }
        recap.cameraCounts = cameras.sorted { $0.value > $1.value }.map { (camera: $0.key, count: $0.value) }
        recap.labelCounts = labels.sorted { $0.value > $1.value }.map { (label: $0.key, count: $0.value) }
        recap.carriers = carriers.sorted { $0.value > $1.value }.map { (name: $0.key, count: $0.value) }
        recap.busiestHour = hours.max { $0.value < $1.value }?.key
        recap.people = people.sorted()
        let times = events.compactMap(\.startTime)
        recap.firstAt = times.min().map { Date(timeIntervalSince1970: $0) }
        recap.lastAt = times.max().map { Date(timeIntervalSince1970: $0) }
        return recap
    }
}

/// Schedule for the optional daily-recap notification, persisted locally.
enum RecapSettings {
    private static let d = UserDefaults.standard

    static var enabled: Bool {
        get { d.bool(forKey: "apex.recap.enabled") }
        set { d.set(newValue, forKey: "apex.recap.enabled") }
    }
    static var hour: Int {
        get { d.object(forKey: "apex.recap.hour") as? Int ?? 21 }
        set { d.set(newValue, forKey: "apex.recap.hour") }
    }
    static var minute: Int {
        get { d.object(forKey: "apex.recap.minute") as? Int ?? 0 }
        set { d.set(newValue, forKey: "apex.recap.minute") }
    }
    private static var lastSentDay: String {
        get { d.string(forKey: "apex.recap.lastSent") ?? "" }
        set { d.set(newValue, forKey: "apex.recap.lastSent") }
    }

    static func todayKey() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    /// True if it's at/after the chosen time and we haven't already sent today's recap.
    static func shouldSendNow() -> Bool {
        guard enabled else { return false }
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let current = (now.hour ?? 0) * 60 + (now.minute ?? 0)
        return current >= (hour * 60 + minute) && lastSentDay != todayKey()
    }

    static func markSentToday() { lastSentDay = todayKey() }
}
