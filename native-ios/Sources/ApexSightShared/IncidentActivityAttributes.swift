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
    /// Epoch seconds (not Date) so the relay can start/update this activity via an APNs
    /// push: ActivityKit decodes push JSON numbers cleanly, avoiding Date-encoding ambiguity.
    var startedAt: Double
}
