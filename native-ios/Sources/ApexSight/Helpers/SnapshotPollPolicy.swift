import Foundation

/// How often a camera tile on the wall asks Frigate for a new frame.
///
/// The wall used to poll on a **fixed** 3-second tick with no failure path at all: a fetch that
/// errored was swallowed and the next one fired 3 seconds later, forever, at the same rate. That
/// is fine against a healthy server on the LAN — it is what makes the wall feel live — and wrong
/// against a struggling one reached over a tunnel, where a constant request rate is load added to
/// a server already failing to answer.
///
/// So the cadence follows the server instead of ignoring it:
/// - **Fast when it's fast.** A frame that came back quickly keeps the original ~3s rhythm, which
///   is the Ring/Nest/UniFi wall feel this app is built around.
/// - **Slower when it's slow.** The next request waits proportionally to how long the last one
///   took, so a tile can never occupy the server more than roughly half the time, and nine tiles
///   can't collectively pile on.
/// - **A heartbeat when it's failing.** After sustained failure the tile drops to one request a
///   minute. Deliberately *not* a full stop: a security wall that silently stops updating until
///   the user thinks to interact is a worse failure than one that quietly keeps checking, and at
///   one request per minute per camera the load is negligible.
///
/// Pure and total so it can be tested without a network — the same reason `GateSyncPolicy` and
/// `ReviewStillPolicy` are pure.
enum SnapshotPollPolicy {
    /// The wall's natural rhythm when the server answers promptly.
    static let base: TimeInterval = 3
    /// Nothing ever waits longer than this, so a recovered server is picked up within a minute.
    static let maxDelay: TimeInterval = 60
    /// Consecutive failures after which the tile drops to the heartbeat.
    static let failuresBeforeHeartbeat = 5

    enum Next: Equatable {
        /// Normal operation: wait this long, then fetch again.
        case wait(TimeInterval)
        /// Sustained failure: keep checking, but only just enough to notice a recovery.
        case heartbeat(TimeInterval)

        var delay: TimeInterval {
            switch self {
            case .wait(let d), .heartbeat(let d): return d
            }
        }
    }

    /// - Parameters:
    ///   - lastDuration: how long the previous fetch took, or nil if it failed/never ran.
    ///   - consecutiveFailures: failures since the last frame arrived.
    static func next(lastDuration: TimeInterval?, consecutiveFailures: Int) -> Next {
        if consecutiveFailures >= failuresBeforeHeartbeat { return .heartbeat(maxDelay) }

        if consecutiveFailures > 0 {
            // 3s, 6s, 12s, 24s — exponential, so a server that is down isn't asked at the same
            // rate as one that blinked.
            let backoff = base * pow(2, Double(consecutiveFailures - 1))
            return .wait(min(backoff, maxDelay))
        }

        // Success. Give the server at least as long as it just spent answering, so a slow link
        // stretches the cadence on its own without anyone having to detect "slow".
        guard let lastDuration, lastDuration.isFinite, lastDuration > 0 else { return .wait(base) }
        return .wait(min(max(base, lastDuration * 2), maxDelay))
    }
}
