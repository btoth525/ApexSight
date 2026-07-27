import Testing
@testable import ApexSightNative

/// Regression guards for the arm/snooze gate mirror — the decision that determines whether the
/// household's cameras go quiet. Both failure directions are real bugs that shipped:
///
///  • over-posting: a cold launch re-imposed this phone's stale local snooze over household state,
///    so a snooze the other phone had just cleared came straight back;
///  • under-posting: persisting the OPTIMISTIC marker meant a POST that failed just before the app
///    was killed looked permanently synced, and the gate never re-synced — fail-CLOSED.
///
/// The split between "attempted (in-memory)" and "confirmed (persisted)" is what makes both safe,
/// so these pin that the two are not interchangeable.
@Suite("GateSyncPolicy")
struct GateSyncPolicyTests {
    private let snoozed = GateSyncPolicy.signature(disarmed: false, snoozedUntil: 1_785_000_000)
    private let clear = GateSyncPolicy.signature(disarmed: false, snoozedUntil: 0)

    // MARK: - shouldPost

    @Test("Posts when nothing has been sent yet")
    func postsWhenFresh() {
        #expect(GateSyncPolicy.shouldPost(signature: snoozed, inFlight: nil, confirmed: nil))
    }

    @Test("Skips a state already in flight this session (no repeat POST every 15s poll)")
    func skipsInFlight() {
        #expect(!GateSyncPolicy.shouldPost(signature: snoozed, inFlight: snoozed, confirmed: nil))
    }

    @Test("Skips a state the relay already confirmed — this is the cold-launch guard")
    func skipsConfirmed() {
        // Cold launch: in-flight is nil because it doesn't persist. Without the confirmed check
        // this would re-POST the local snooze and re-silence the household.
        #expect(!GateSyncPolicy.shouldPost(signature: snoozed, inFlight: nil, confirmed: snoozed))
    }

    @Test("Re-posts after a failed POST that never got confirmed — the fail-CLOSED guard")
    func retriesUnconfirmed() {
        // The app was killed after the optimistic mark but before the rollback. Because only
        // CONFIRMED is persisted, the next launch still posts.
        #expect(GateSyncPolicy.shouldPost(signature: snoozed, inFlight: nil, confirmed: clear))
    }

    @Test("A changed state posts even though an older one was confirmed")
    func postsOnChange() {
        #expect(GateSyncPolicy.shouldPost(signature: clear, inFlight: snoozed, confirmed: snoozed))
    }

    // MARK: - shouldAdoptClear

    @Test("Adopts another phone's resume")
    func adoptsRemoteClear() {
        #expect(GateSyncPolicy.shouldAdoptClear(
            relaySnoozedUntil: 0, hasLocalSnooze: true, currentSignature: snoozed,
            confirmed: snoozed, confirmedAt: 100, fetchStartedAt: 200))
    }

    @Test("Does NOT adopt when our snooze was never confirmed by the relay")
    func ignoresUnconfirmed() {
        // The relay reports no snooze because ours hasn't landed yet — not because anyone cleared
        // it. Adopting here would cancel the user's own snooze.
        #expect(!GateSyncPolicy.shouldAdoptClear(
            relaySnoozedUntil: 0, hasLocalSnooze: true, currentSignature: snoozed,
            confirmed: nil, confirmedAt: 0, fetchStartedAt: 200))
    }

    @Test("Does NOT adopt a /v1/mode response that was in flight BEFORE our snooze confirmed")
    func ignoresStaleRead() {
        // The read started at 50, our POST confirmed at 100 — the response predates the snooze,
        // so it cannot report it. Both are kicked off from the same 15s poll tick.
        #expect(!GateSyncPolicy.shouldAdoptClear(
            relaySnoozedUntil: 0, hasLocalSnooze: true, currentSignature: snoozed,
            confirmed: snoozed, confirmedAt: 100, fetchStartedAt: 50))
    }

    @Test("Does NOT adopt when the relay still HAS a snooze")
    func ignoresActiveRelaySnooze() {
        #expect(!GateSyncPolicy.shouldAdoptClear(
            relaySnoozedUntil: 1_785_000_000, hasLocalSnooze: true, currentSignature: snoozed,
            confirmed: snoozed, confirmedAt: 100, fetchStartedAt: 200))
    }

    @Test("Does NOT adopt when this phone has no local snooze to clear")
    func ignoresWhenNothingLocal() {
        #expect(!GateSyncPolicy.shouldAdoptClear(
            relaySnoozedUntil: 0, hasLocalSnooze: false, currentSignature: clear,
            confirmed: clear, confirmedAt: 100, fetchStartedAt: 200))
    }

    @Test("Does NOT adopt when local state drifted from what was confirmed")
    func ignoresSignatureMismatch() {
        // The user changed the snooze after it was confirmed; the relay's "no snooze" refers to
        // the older value, so adopting would discard the newer one.
        let newer = GateSyncPolicy.signature(disarmed: false, snoozedUntil: 1_785_009_999)
        #expect(!GateSyncPolicy.shouldAdoptClear(
            relaySnoozedUntil: 0, hasLocalSnooze: true, currentSignature: newer,
            confirmed: snoozed, confirmedAt: 100, fetchStartedAt: 200))
    }

    // MARK: - signature

    @Test("Signature truncates sub-second drift so it stays stable across polls")
    func signatureIsStable() {
        #expect(GateSyncPolicy.signature(disarmed: false, snoozedUntil: 1_785_000_000.4)
                == GateSyncPolicy.signature(disarmed: false, snoozedUntil: 1_785_000_000.9))
    }

    @Test("Disarm is part of the signature")
    func signatureCoversDisarm() {
        #expect(GateSyncPolicy.signature(disarmed: true, snoozedUntil: 0)
                != GateSyncPolicy.signature(disarmed: false, snoozedUntil: 0))
    }
}
