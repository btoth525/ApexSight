import Foundation
import Testing
@testable import ApexSightNative

/// Regression guards for the per-device Focus mute.
///
/// The bug these exist to prevent: the iOS Focus filter used to write `GlobalSnooze` and POST
/// `/v1/gate`, which is HOUSEHOLD state — so one partner turning on Do Not Disturb silenced every
/// phone's camera alerts for eight hours, invisibly. A Focus belongs to one person's device and
/// must never make a security decision for the whole house.
///
/// The load-bearing invariant is the SEPARATION: `FocusSnooze` and `GlobalSnooze` are distinct
/// stores backed by distinct app-group keys, so muting one can never mute the other.
@Suite("FocusSnooze", .serialized)
struct FocusSnoozeTests {
    /// Both stores read/write the real app-group defaults, so each test restores what it found.
    private func withCleanSnoozeState(_ body: () throws -> Void) rethrows {
        let priorFocus = FocusSnooze.until
        let priorGlobal = GlobalSnooze.until
        FocusSnooze.clear()
        GlobalSnooze.clear()
        defer {
            if let priorFocus { FocusSnooze.mute(until: priorFocus) } else { FocusSnooze.clear() }
            if let priorGlobal { GlobalSnooze.snooze(until: priorGlobal) } else { GlobalSnooze.clear() }
        }
        try body()
    }

    @Test("A Focus mute does NOT set the household snooze")
    func focusMuteLeavesHouseholdAlone() {
        withCleanSnoozeState {
            FocusSnooze.mute(until: Date().addingTimeInterval(8 * 60 * 60))
            #expect(FocusSnooze.isActive)
            // The whole point: the household gate must be untouched, so the OTHER phone keeps
            // getting alerts while this one is in Do Not Disturb.
            #expect(!GlobalSnooze.isActive, "an iOS Focus must never silence the household")
        }
    }

    @Test("A household snooze does NOT set this device's Focus mute")
    func householdSnoozeLeavesFocusAlone() {
        withCleanSnoozeState {
            GlobalSnooze.snooze(until: Date().addingTimeInterval(60 * 60))
            #expect(GlobalSnooze.isActive)
            #expect(!FocusSnooze.isActive)
        }
    }

    @Test("Clearing the Focus mute leaves a deliberate household snooze intact")
    func clearingFocusKeepsHouseholdSnooze() {
        withCleanSnoozeState {
            GlobalSnooze.snooze(until: Date().addingTimeInterval(60 * 60))
            FocusSnooze.mute(until: Date().addingTimeInterval(8 * 60 * 60))
            // A Focus ending must not cancel a snooze someone actually chose — the old code called
            // GlobalSnooze.clear() here and silently undid it.
            FocusSnooze.clear()
            #expect(!FocusSnooze.isActive)
            #expect(GlobalSnooze.isActive, "a Focus ending must not cancel a deliberate household snooze")
        }
    }

    @Test("An expired Focus mute reads as inactive")
    func expiredFocusMuteIsInactive() {
        withCleanSnoozeState {
            FocusSnooze.mute(until: Date().addingTimeInterval(-60))
            #expect(!FocusSnooze.isActive)
            #expect(FocusSnooze.until == nil)
        }
    }

    @Test("epochForSync is 0 when not muted, so a sync CLEARS the relay's stored value")
    func epochForSyncZeroWhenClear() {
        withCleanSnoozeState {
            FocusSnooze.clear()
            #expect(FocusSnooze.epochForSync == 0)
            // Expired counts as clear too — otherwise a stale deadline would keep re-muting.
            FocusSnooze.mute(until: Date().addingTimeInterval(-60))
            #expect(FocusSnooze.epochForSync == 0)
        }
    }

    @Test("epochForSync round-trips an active mute")
    func epochForSyncRoundTrips() {
        withCleanSnoozeState {
            let target = Date().addingTimeInterval(4 * 60 * 60)
            FocusSnooze.mute(until: target)
            #expect(abs(FocusSnooze.epochForSync - target.timeIntervalSince1970) < 0.001)
        }
    }

    // NotificationPreferencesStore is main-actor isolated (it drives UI), so this one runs there.
    @MainActor
    @Test("The local delivery gate honors this device's Focus mute")
    func localGateHonorsFocusMute() {
        withCleanSnoozeState {
            let store = NotificationPreferencesStore()
            let deliveredBefore = store.wouldDeliver(
                camera: "front_door", label: "person", zones: [], score: 0.9, triggers: []
            )
            #expect(deliveredBefore, "precondition: nothing else is muting this event")

            FocusSnooze.mute(until: Date().addingTimeInterval(60 * 60))
            #expect(!store.wouldDeliver(
                camera: "front_door", label: "person", zones: [], score: 0.9, triggers: []
            ), "a Focus mute must suppress this phone's own alerts too")
        }
    }
}
