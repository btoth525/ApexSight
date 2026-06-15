import ActivityKit
import Foundation

/// Shared between the app (which starts/updates the Activity) and the widget
/// extension (which renders the Lock Screen / Dynamic Island UI).
struct IncidentActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var detail: String
        var severity: String
    }

    var camera: String
    var startedAt: Date
}
