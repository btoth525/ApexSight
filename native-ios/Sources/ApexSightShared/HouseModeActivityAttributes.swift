import ActivityKit
import Foundation

/// Live Activity for a house-mode arm — shown on the Lock Screen + Dynamic Island when you arm
/// Away/Night from the app. Shared so the app starts/updates/ends it and the widget renders it.
struct HouseModeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var mode: String     // "away" | "night"
        var by: String       // who armed it (phone name)
        /// Epoch seconds the exit-delay countdown ends. In the future → "Arming"; past/0 → "Armed".
        var endsAt: Double
    }
    var startedAt: Double
}
