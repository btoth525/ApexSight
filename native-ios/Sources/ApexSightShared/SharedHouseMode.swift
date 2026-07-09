import Foundation

/// House mode (Home / Night / Away — the Alarmo-mirrored state) shared into the app group so the
/// Lock Screen widgets, Control Center controls, and the Live Activity can all read it without the
/// main app running. The app writes it on every relay poll (AppState.refreshHouseMode); the widget
/// extension only ever reads. Foundation-only so it compiles in the extension.
public enum SharedHouseMode {
    private static let modeKey = "apex.houseMode"
    private static let byKey = "apex.houseModeArmedBy"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: ApexAppGroup.identifier) }

    /// Raw mode: "home" | "away" | "night" | "" (unknown / relay not yet reported).
    public static var mode: String {
        get { defaults?.string(forKey: modeKey) ?? "" }
        set { defaults?.set(newValue, forKey: modeKey) }
    }

    /// Who last set it (device name), for display. Empty when unknown.
    public static var armedBy: String {
        get { defaults?.string(forKey: byKey) ?? "" }
        set { defaults?.set(newValue, forKey: byKey) }
    }

    // MARK: - Display helpers (Foundation-safe; colors live in the SwiftUI layer)

    public static func title(_ m: String) -> String {
        switch m {
        case "home": return "Home"
        case "away": return "Away"
        case "night": return "Night"
        default: return "Unknown"
        }
    }

    public static func symbol(_ m: String) -> String {
        switch m {
        case "home": return "house.fill"
        case "away": return "shield.lefthalf.filled"
        case "night": return "moon.stars.fill"
        default: return "shield.lefthalf.filled"
        }
    }

    /// Short status line for a rectangular widget / Live Activity subtitle.
    public static func subtitle(_ m: String) -> String {
        switch m {
        case "home": return "Front cameras only"
        case "away": return "All cameras armed"
        case "night": return "Perimeter armed"
        default: return "Tap to arm or disarm"
        }
    }
}
