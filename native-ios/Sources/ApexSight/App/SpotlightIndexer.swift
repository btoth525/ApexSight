import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// Indexes recent Frigate events into iOS Spotlight so the user can search "package", "UPS",
/// "person", a plate, etc. from the Home Screen search and jump straight to the event.
///
/// Privacy: metadata only (label / camera / sub-label / zone / plate + time) — NO snapshots are
/// indexed. Opt-out via Settings (`spotlightEventsEnabled`, default on). Each item's identifier is
/// the `apex://event?id=…` deep link, so a tap routes through the existing handler.
enum SpotlightIndexer {
    static let domain = "apex.events"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "spotlightEventsEnabled") as? Bool ?? true
    }

    /// Reindex the given events (replaces the domain's contents). Cheap; call on refresh.
    static func index(_ events: [FrigateEvent]) {
        guard enabled else { clear(); return }
        guard !events.isEmpty else { return }

        let items = events.prefix(150).map { e -> CSSearchableItem in
            let attr = CSSearchableItemAttributeSet(contentType: UTType.content)
            let cam = titleize(e.camera)
            let subject = (e.subLabel?.isEmpty == false) ? titleize(e.subLabel!) : titleize(e.label)
            attr.title = "\(subject) at \(cam)"

            var keywords = [e.label, e.camera.replacingOccurrences(of: "_", with: " ")]
            if let s = e.subLabel, !s.isEmpty { keywords.append(s) }
            if let face = e.recognizedFace, !face.isEmpty { keywords.append(face) }
            if let plate = e.recognizedLicensePlate, !plate.isEmpty { keywords.append(plate) }
            if let zones = e.zones { keywords.append(contentsOf: zones) }
            attr.keywords = keywords

            var desc = cam
            if let zones = e.zones, let z = zones.first { desc += " • \(titleize(z))" }
            attr.contentDescription = desc
            if let t = e.startTime { attr.contentCreationDate = Date(timeIntervalSince1970: t) }

            // Identifier IS the deep link — the tap handler routes it straight to the event.
            return CSSearchableItem(
                uniqueIdentifier: "apex://event?id=\(e.id)",
                domainIdentifier: domain,
                attributeSet: attr
            )
        }
        // Truly REPLACE the domain's contents. indexSearchableItems alone only upserts, so events
        // that have scrolled out of the rolling window — or that Frigate has since purged — would
        // linger in the index forever and surface dead apex://event links from Spotlight. Clear the
        // domain first, then index the current window. (Called only when the event set changes, per
        // AppState's eventSignature guard, so this isn't run on every poll.)
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(Array(items)) { _ in }
        }
    }

    static func clear() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in }
    }
}
