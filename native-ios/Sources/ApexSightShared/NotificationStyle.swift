import Foundation

/// User-tunable look & feel for ApexSight notifications. The app syncs this to the
/// push relay (POST /v1/style) so even app-closed instant pushes are rendered the
/// way the user configured, and uses it locally for foreground/background alerts.
/// Field names are the JSON contract the relay's render.py expects — keep in sync.
struct NotificationStyle: Codable, Equatable {
    // Content
    var subLabelFirst: Bool = true       // recognized face/plate/carrier becomes the headline
    var severityPrefix: Bool = true      // 🚨 in front of alert-severity titles
    var showEmojis: Bool = true
    /// User overrides layered on top of the relay's built-in emoji map (label → emoji).
    var emojiMap: [String: String] = [:]

    // Message fields
    var showEntities: Bool = true
    var showZone: Bool = true
    var showConfidence: Bool = true
    var showTime: Bool = true
    var fieldSeparator: String = " · "

    // Media
    var firstFrame: String = "cropped"   // "cropped" | "full" | "none"
    var finalGif: Bool = true            // send the full-GIF "final update"

    /// App-managed known license plates (Frigate has no plate API). Maps a friendly
    /// name to one or more plate strings; matched normalized (case/space/dash-insensitive).
    var knownPlates: [KnownPlate] = []

    static let `default` = NotificationStyle()
}

struct KnownPlate: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var plates: [String]
}

extension NotificationStyle {
    /// Plate text reduced to just letters/digits, uppercased — for tolerant matching.
    static func normalizePlate(_ raw: String) -> String {
        raw.uppercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    /// The friendly name for a recognized plate, or nil if it isn't one you've named.
    func knownPlateName(for raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let norm = Self.normalizePlate(raw)
        guard !norm.isEmpty else { return nil }
        for plate in knownPlates where plate.plates.contains(where: { Self.normalizePlate($0) == norm }) {
            return plate.name
        }
        return nil
    }
}
