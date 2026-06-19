import ActivityKit
import Foundation

/// Registers this device's Live Activity *push-to-start* token with the relay so an
/// incident banner can appear on the Lock Screen / Dynamic Island even when the app is
/// fully closed — the relay starts (and refreshes) it via APNs. Requires iOS 17.2+;
/// on older systems the app falls back to starting the activity itself while running.
@MainActor
enum LiveActivityPushManager {
    private static var observing = false

    /// Begin streaming push-to-start tokens to the relay. Idempotent — safe to call on
    /// every launch / foreground.
    static func start() {
        guard !observing else { return }
        observing = true
        if #available(iOS 17.2, *) {
            observeStartTokens()
        }
    }

    @available(iOS 17.2, *)
    private static func observeStartTokens() {
        Task {
            for await tokenData in Activity<IncidentActivityAttributes>.pushToStartTokenUpdates {
                let token = tokenData.map { String(format: "%02x", $0) }.joined()
                await register(token: token)
            }
        }
    }

    private static func register(token: String) async {
        guard !token.isEmpty else { return }
        let relay = DeviceTokenStore.relayURL
        let pairing = DeviceTokenStore.ensurePairingCode()
        guard !relay.isEmpty, !pairing.isEmpty else { return }
        try? await RelayClient.registerActivity(
            relayURL: relay,
            pairingCode: pairing,
            token: token,
            environment: APNSEnvironment.current
        )
    }
}
