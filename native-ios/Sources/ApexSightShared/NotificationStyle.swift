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

    static let `default` = NotificationStyle()
}
