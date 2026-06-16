import Foundation

/// Security/arm mode, shared across the app, widgets, controls, Siri and Focus.
/// "disarmed" silences all alerts; the other modes keep alerts on (and leave room
/// for per-mode rules later).
public enum ArmMode: String, Codable, CaseIterable {
    case disarmed, home, away, night

    var title: String {
        switch self {
        case .disarmed: return "Disarmed"
        case .home: return "Home"
        case .away: return "Away"
        case .night: return "Night"
        }
    }

    var systemImage: String {
        switch self {
        case .disarmed: return "shield.slash.fill"
        case .home: return "house.fill"
        case .away: return "figure.walk.departure"
        case .night: return "moon.stars.fill"
        }
    }
}

enum ArmStateStore {
    private static let key = "apex.armMode"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: ApexAppGroup.identifier) }

    static var mode: ArmMode {
        get { ArmMode(rawValue: defaults?.string(forKey: key) ?? "") ?? .away }
        set {
            defaults?.set(newValue.rawValue, forKey: key)
            // Keep widgets + the Control Center arm toggle in sync wherever the change came from.
            ApexSurfaceRefresh.reload()
        }
    }

    /// Whether alerts should be delivered at all in the current mode.
    static var notificationsActive: Bool { mode != .disarmed }
}
