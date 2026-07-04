import Foundation

/// A cluster of related events that tells one story — a burst of activity on a camera, or a subject
/// moving across cameras. Built client-side by time-clustering events (Frigate has no cross-camera
/// track id, so this is proximity-based; sub-labels, when present, make the link explicit).
struct Incident: Identifiable, Hashable {
    /// The events in this incident, oldest → newest.
    let events: [FrigateEvent]

    var id: String { events.first?.id ?? UUID().uuidString }

    /// Distinct cameras in the order the subject first appeared on them (the "path").
    var cameraPath: [String] {
        var seen = Set<String>()
        var order: [String] = []
        for e in events where !seen.contains(e.camera) {
            seen.insert(e.camera); order.append(e.camera)
        }
        return order
    }

    /// The camera with the most events — the incident's "home" camera.
    var primaryCamera: String {
        let counts = Dictionary(grouping: events, by: { $0.camera }).mapValues(\.count)
        return counts.max { $0.value < $1.value }?.key ?? events.first?.camera ?? ""
    }

    /// Cameras with a REAL presence (≥2 events) — filters out a single stray detection on another
    /// camera so we don't overclaim "tracked across N cameras" for what's really one-camera activity.
    var significantCameras: [String] {
        let counts = Dictionary(grouping: events, by: { $0.camera }).mapValues(\.count)
        return cameraPath.filter { (counts[$0] ?? 0) >= 2 }
    }

    /// Genuine cross-camera movement: two or more cameras each saw sustained activity.
    var isCrossCamera: Bool { significantCameras.count > 1 }

    /// Which cameras to actually export — every significant camera for a true cross-camera
    /// incident, else just the home camera.
    var exportCameras: [String] { isCrossCamera ? significantCameras : [primaryCamera] }

    var start: Double { events.compactMap(\.startTime).min() ?? 0 }
    var end: Double {
        // An in-progress event may have no endTime yet — fall back to its start.
        events.map { $0.endTime ?? $0.startTime ?? 0 }.max() ?? start
    }
    var startDate: Date { Date(timeIntervalSince1970: start) }
    var endDate: Date { Date(timeIntervalSince1970: end) }
    var duration: TimeInterval { max(0, end - start) }

    /// The most significant subject: a recognized sub-label wins (a name/plate), else the most
    /// common object label.
    var headline: String {
        if let named = events.compactMap({ $0.subLabel?.isEmpty == false ? $0.subLabel : nil }).first {
            return named
        }
        let counts = Dictionary(grouping: events, by: { $0.label }).mapValues(\.count)
        return counts.max(by: { $0.value < $1.value })?.key ?? "activity"
    }

    /// Distinct object labels present, most common first.
    var labels: [String] {
        let counts = Dictionary(grouping: events, by: { $0.label }).mapValues(\.count)
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }

    /// Best event to show a thumbnail for (prefers one with a snapshot).
    var thumbnailEvent: FrigateEvent {
        events.first { $0.hasSnapshot == true } ?? events[0]
    }

    var hasAlert: Bool { events.contains { $0.label == "person" } }

    /// Export window per camera: that camera's own span within the incident, padded a touch so the
    /// subject's entry/exit isn't clipped. One entry per meaningful camera (see `exportCameras`).
    func exportWindows(pad: TimeInterval = 3) -> [(camera: String, start: Double, end: Double)] {
        exportCameras.map { cam in
            let cameraEvents = events.filter { $0.camera == cam }
            let s = (cameraEvents.compactMap(\.startTime).min() ?? start) - pad
            let e = (cameraEvents.map { $0.endTime ?? $0.startTime ?? end }.max() ?? end) + pad
            return (cam, s, e)
        }
    }
}

enum IncidentBuilder {
    /// Cluster events into incidents. A new incident starts when an event begins more than `gap`
    /// seconds after the running cluster's latest activity. Returns newest-first.
    static func build(from events: [FrigateEvent], gap: TimeInterval = 120) -> [Incident] {
        let sorted = events
            .filter { $0.startTime != nil }
            .sorted { ($0.startTime ?? 0) < ($1.startTime ?? 0) }
        guard !sorted.isEmpty else { return [] }

        var clusters: [[FrigateEvent]] = []
        var current: [FrigateEvent] = []
        var clusterEnd: Double = -.greatestFiniteMagnitude

        for event in sorted {
            let s = event.startTime ?? 0
            if current.isEmpty || s - clusterEnd <= gap {
                current.append(event)
            } else {
                clusters.append(current)
                current = [event]
            }
            clusterEnd = max(clusterEnd, event.endTime ?? s)
        }
        if !current.isEmpty { clusters.append(current) }

        return clusters
            .map { Incident(events: $0) }
            .sorted { $0.start > $1.start }
    }
}
