import SwiftUI

/// How Frigate's `potential_threat_level` is presented.
///
/// Extracted as a pure mapping (same reasoning as `HouseModeVisibility` and `GateSyncPolicy`) so
/// the thresholds are testable without building a view — and so "what counts as concerning" lives
/// in exactly one place rather than being re-invented at each call site.
///
/// FAIL-QUIET is the rule: an absent or unrecognised level renders as `.routine`, never as an
/// alarm. A language model produced this number; a decode hiccup must not scream at someone.
enum ThreatLevel: Int, Comparable, CaseIterable {
    case routine = 0        // Frigate's "Level 0" — known people, deliveries, normal traffic
    case notable = 1        // worth a glance
    case concerning = 2     // worth acting on

    static func < (a: ThreatLevel, b: ThreatLevel) -> Bool { a.rawValue < b.rawValue }

    /// Clamps anything Frigate sends into a level we can render. Nil and negatives read as routine;
    /// anything above the top level saturates rather than disappearing.
    init(raw: Int?) {
        switch raw ?? 0 {
        case ..<1: self = .routine
        case 1: self = .notable
        default: self = .concerning
        }
    }

    var label: String {
        switch self {
        case .routine: return "Routine"
        case .notable: return "Notable"
        case .concerning: return "Worth a look"
        }
    }

    var symbol: String {
        switch self {
        case .routine: return "checkmark.seal.fill"
        case .notable: return "eye.fill"
        case .concerning: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .routine: return GlassTheme.green
        case .notable: return GlassTheme.orange
        case .concerning: return GlassTheme.red
        }
    }

    /// Whether this level should draw attention in a dense list. Routine activity is the vast
    /// majority, so badging it everywhere would just add noise and train people to ignore it.
    var deservesRowBadge: Bool { self != .routine }
}
