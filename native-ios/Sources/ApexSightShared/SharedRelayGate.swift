import Foundation

/// Mirrors the current arm/snooze gate to the push relay from code that runs OUTSIDE the main
/// app — Siri App Intents (openAppWhenRun = false), Control Center controls, widget buttons, and
/// the Focus filter all live in `SharedActionIntents` (compiled into the widget extension), which
/// can't reach the main app's `RelayGate`/`RelayClient`. Without this, disarming or snoozing from
/// any of those surfaces quiets only the in-app gate while the relay keeps sending pushes until the
/// next app foreground — a real miss for a security app.
///
/// Self-contained on purpose (Foundation + the app-group state already in this target), so it
/// builds in the extension without dragging the whole networking stack across the target boundary.
public enum SharedRelayGate {
    /// POST the current Disarm + Snooze state to the relay's `/v1/gate`. No-op if pairing/relay
    /// aren't configured yet.
    ///
    /// Retries when the post RESUMES alerts (not disarmed, not snoozed). The two directions carry
    /// very different risk: a dropped "silence" POST just means a few extra notifications, but a
    /// dropped "resume" leaves the whole household silent until someone opens the app — fail-CLOSED
    /// on a security app. "The next foreground re-syncs" is not an acceptable answer for that one.
    static func syncCurrent() async {
        let disarmed = !ArmStateStore.notificationsActive
        let snoozedUntil = GlobalSnooze.until?.timeIntervalSince1970 ?? 0
        let resuming = !disarmed && snoozedUntil == 0
        let attempts = resuming ? 3 : 1
        for attempt in 0..<attempts {
            if await post(disarmed: disarmed, snoozedUntil: snoozedUntil) { return }
            if attempt < attempts - 1 {
                // Bounded and short — the extension's runtime is limited, so an open-ended retry
                // loop would just get suspended rather than eventually succeeding.
                try? await Task.sleep(nanoseconds: attempt == 0 ? 1_000_000_000 : 3_000_000_000)
            }
        }
    }

    /// One `/v1/gate` POST attempt. Returns true only on a 2xx — anything else is worth retrying.
    @discardableResult
    private static func post(disarmed: Bool, snoozedUntil: Double) async -> Bool {
        let defaults = UserDefaults(suiteName: ApexAppGroup.identifier)
        let relayURL = nonEmpty(defaults?.string(forKey: "apex.relayURL")) ?? RelayConfig.defaultURL
        guard let pairing = nonEmpty(defaults?.string(forKey: "apex.pairingCode")) ?? nonEmpty(RelayConfig.defaultPairingCode) else { return false }

        var trimmed = relayURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + "/v1/gate"),
              url.scheme == "https", url.host != nil else { return false }

        // Keys must match the main app's RelayClient.GateBody (snake_case).
        let body: [String: Any] = [
            "pairing_code": pairing,
            "disarmed": disarmed,
            "snoozed_until": snoozedUntil,
            // Attribution for the app's banner. A gate change from a widget / Control Center /
            // Siri is exactly the kind that leaves someone asking "why did alerts stop?".
            "by": nonEmpty(defaults?.string(forKey: "apex.deviceName")) ?? "Another device"
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody
        request.timeoutInterval = 15
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// Request a house-mode change from OUTSIDE the app (Control Center control, widget button,
    /// Live Activity action). Mirrors RelayClient.setMode: arming rides the pairing code; disarming
    /// ("home") must carry `code`, which Alarmo validates server-side. Best-effort.
    static func setHouseMode(_ mode: String, code: String = "") async {
        let defaults = UserDefaults(suiteName: ApexAppGroup.identifier)
        let relayURL = nonEmpty(defaults?.string(forKey: "apex.relayURL")) ?? RelayConfig.defaultURL
        guard let pairing = nonEmpty(defaults?.string(forKey: "apex.pairingCode")) ?? nonEmpty(RelayConfig.defaultPairingCode) else { return }
        var trimmed = relayURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + "/v1/set-mode"), url.scheme != nil, url.host != nil else { return }

        let token = defaults?.string(forKey: "apex.apnsDeviceToken") ?? ""
        // Keys must match the main app's RelayClient SetModeBody (snake_case).
        let body: [String: Any] = [
            "mode": mode,
            "device_token": token,
            "pairing_code": pairing,
            "code": code
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody
        request.timeoutInterval = 15
        _ = try? await URLSession.shared.data(for: request)
        // Optimistically reflect the arm locally so the widgets/controls update before the next poll.
        if !mode.isEmpty { SharedHouseMode.mode = mode }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
