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

    /// The model's own confidence below which an ESCALATION is not believed.
    ///
    /// Measured across 61 rated reviews on the live server: every legitimate Level 1 carried
    /// confidence 0.5–1.0, while the single Level 2 — a fabricated "Forced Entry Attempt", complete
    /// with an imagined crowbar, raised against two RECOGNISED RESIDENTS carrying a package —
    /// carried **0.02**. The model contradicted itself inside its own observations ("possibly a
    /// package or a parcel", then "a tool that resembles a crowbar"). 0.35 sits in the empty gap
    /// between those two populations with room on both sides.
    static let confidenceFloor = 0.35
}

extension ThreatLevel {
    /// The level to ACT on, or nil when the rating shouldn't be believed.
    ///
    /// Returning nil means "unrated" — no badge, no dot, no interruption — which is deliberately
    /// NOT the same as `.routine`. Routine is a positive statement ("the model looked and this is
    /// normal", shown as a green dot); an untrusted rating is an absence of information, and
    /// dressing it up as an all-clear would be its own lie.
    ///
    /// Two things make a rating untrustworthy, both learned from real false positives:
    ///
    /// 1. **The model says it isn't sure.** An escalation asserted at 0.02 confidence woke the
    ///    house for a fiction. Level 0 is exempt: "nothing to see" is the safe answer regardless of
    ///    how sure it is, and requiring confidence there would turn quiet reviews into alarms.
    /// 2. **The subject is a recognised person.** Frigate labels those `person-verified`, i.e. face
    ///    recognition matched a household member. The rubric already says a verified person is
    ///    Level 0 "regardless of time or activity" and the model ignored it — so it's enforced in
    ///    code, where a prompt can't be argued with.
    ///
    /// Both guards only ever REDUCE an escalation. Neither can suppress a real alert: the
    /// notification itself is already sent by this point, and this decides only how loudly it
    /// presents. Never let it gate delivery.
    static func trusted(raw: Int?, confidence: Double?, objects: [String]) -> ThreatLevel? {
        let level = ThreatLevel(raw: raw)
        guard level != .routine else { return .routine }

        if objects.contains(where: { $0.lowercased().contains("verified") }) { return nil }
        guard let confidence, confidence.isFinite, confidence >= confidenceFloor else { return nil }
        return level
    }
}
