import Foundation

/// Single place to mirror the current arm/snooze gate to the relay, independent of
/// `AppState`. App-closed entry points (Siri intents, the watch, notification actions)
/// all change `GlobalSnooze` while the app's 15s foreground poll — which normally pushes
/// the gate via `AppState.syncRelayGateIfChanged` — isn't running. Without this, an
/// app-closed snooze quiets the in-app gate but the relay keeps sending pushes until the
/// next foreground. Route every background gate change through here so it takes effect now.
enum RelayGate {
    /// Push the gate with an explicit snooze time (0 = not snoozed). Reads the disarm
    /// state from `ArmStateStore`. No-op when pairing isn't configured yet.
    static func sync(snoozedUntil: TimeInterval) async {
        let relayURL = DeviceTokenStore.relayURL
        let pairing = DeviceTokenStore.ensurePairingCode()
        guard !relayURL.isEmpty, !pairing.isEmpty else { return }
        let disarmed = !ArmStateStore.notificationsActive
        try? await RelayClient.syncGate(
            relayURL: relayURL, pairingCode: pairing,
            disarmed: disarmed, snoozedUntil: snoozedUntil
        )
    }

    /// Push the gate reading the live snooze state from `GlobalSnooze` (use after a
    /// mutation that already wrote `GlobalSnooze`, e.g. resume/clear).
    static func syncCurrent() async {
        await sync(snoozedUntil: GlobalSnooze.until?.timeIntervalSince1970 ?? 0)
    }
}
