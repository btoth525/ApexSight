import Foundation

/// The two decisions behind mirroring this phone's arm/snooze gate to the relay, extracted as pure
/// functions so they can be tested without building an `AppState` (which starts `NWPathMonitor` and
/// activates `WatchSyncManager` — the same reason `HouseModeVisibility` was extracted).
///
/// This logic is small but it is the most failure-prone code in the notification path: it decides
/// whether the household's cameras go quiet, and both of its failure directions are bad.
/// Over-posting re-imposes a snooze someone else cleared; under-posting leaves the relay silencing
/// (or alerting) against the user's intent with nothing to correct it.
enum GateSyncPolicy {

    /// Whether to POST the gate for `signature`.
    ///
    /// - `inFlight`: what this app INSTANCE has already attempted (optimistic, rolled back on
    ///   failure, deliberately not persisted).
    /// - `confirmed`: what the relay has actually ACKed (persisted across launches).
    ///
    /// Skipping on `confirmed` is what stops a cold launch from re-imposing this phone's stale
    /// local snooze over household state. Skipping only on `inFlight` would reintroduce that;
    /// persisting `inFlight` instead would mean a POST that failed just before the app was killed
    /// looks permanently synced and never retries.
    static func shouldPost(signature: String, inFlight: String?, confirmed: String?) -> Bool {
        signature != inFlight && signature != confirmed
    }

    /// Whether a relay reporting "no household snooze" should clear THIS phone's local snooze —
    /// i.e. someone else tapped resume and this phone should follow.
    ///
    /// Both guards exist to avoid cancelling a snooze the user just set:
    ///  - the snooze must be one the relay CONFIRMED (an in-flight POST hasn't landed, so its
    ///    absence isn't someone clearing it);
    ///  - the `/v1/mode` read must have STARTED after that confirmation, or a response already in
    ///    flight when we sent the snooze reports the pre-snooze state.
    static func shouldAdoptClear(relaySnoozedUntil: Double,
                                 hasLocalSnooze: Bool,
                                 currentSignature: String,
                                 confirmed: String?,
                                 confirmedAt: Double,
                                 fetchStartedAt: Double) -> Bool {
        guard relaySnoozedUntil == 0, hasLocalSnooze else { return false }
        guard confirmedAt > 0, fetchStartedAt > confirmedAt else { return false }
        return confirmed == currentSignature
    }

    /// The stored form of a gate state. Kept here so the producer and every comparison agree —
    /// a signature built differently in two places silently disables both guards above.
    static func signature(disarmed: Bool, snoozedUntil: Double) -> String {
        "\(disarmed)|\(Int(snoozedUntil))"
    }
}
