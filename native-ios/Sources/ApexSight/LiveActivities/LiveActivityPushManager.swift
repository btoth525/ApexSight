import ActivityKit
import Foundation

/// Registers this device's Live Activity *push-to-start* token with the relay so an
/// incident banner can appear on the Lock Screen / Dynamic Island even when the app is
/// fully closed — the relay starts (and refreshes) it via APNs. Requires iOS 17.2+;
/// on older systems the app falls back to starting the activity itself while running.
@MainActor
enum LiveActivityPushManager {
    private static var observing = false

    /// Begin streaming Live Activity tokens to the relay. Idempotent — safe to call on
    /// every launch / foreground.
    static func start() {
        guard !observing else { return }
        observing = true
        if #available(iOS 17.2, *) {
            observeStartTokens()
        }
        // Update tokens (so the relay can refresh/end a live banner) — iOS 16.1+.
        observeActivityTokens()
    }

    @available(iOS 17.2, *)
    private static func observeStartTokens() {
        Task {
            for await tokenData in Activity<IncidentActivityAttributes>.pushToStartTokenUpdates {
                await register(token: hex(tokenData), kind: "start")
            }
        }
    }

    /// Watch every incident activity (current + newly started, including ones the relay
    /// push-started) and stream its per-activity push token to the relay as an "update"
    /// token, so the relay can live-update or end that specific banner.
    private static func observeActivityTokens() {
        Task {
            for activity in Activity<IncidentActivityAttributes>.activities {
                trackUpdateToken(activity)
            }
            for await activity in Activity<IncidentActivityAttributes>.activityUpdates {
                trackUpdateToken(activity)
            }
        }
    }

    private static func trackUpdateToken(_ activity: Activity<IncidentActivityAttributes>) {
        Task {
            for await tokenData in activity.pushTokenUpdates {
                await register(token: hex(tokenData), kind: "update")
            }
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func register(token: String, kind: String) async {
        guard !token.isEmpty else { return }
        let relay = DeviceTokenStore.relayURL
        let pairing = DeviceTokenStore.ensurePairingCode()
        guard !relay.isEmpty, !pairing.isEmpty else { return }
        try? await RelayClient.registerActivity(
            relayURL: relay,
            pairingCode: pairing,
            token: token,
            environment: APNSEnvironment.current,
            kind: kind
        )
    }
}
