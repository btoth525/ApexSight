import Foundation

/// Mirrors THIS device's Focus mute to the relay from code running OUTSIDE the main app — the
/// Focus filter lives in `SharedActionIntents` (compiled into the widget extension) and can't
/// reach `RelayClient`, exactly like `SharedRelayGate`.
///
/// Deliberately posts ONLY `focus_snoozed_until`, keyed by this device's token, so the relay
/// suppresses pushes for this phone alone. It must never touch `/v1/gate` — see `FocusSnooze`.
enum SharedDevicePrefs {
    /// POST this device's Focus mute to `/v1/device-prefs`.
    ///
    /// Retries, unlike the best-effort `SharedRelayGate.syncCurrent()`. The two directions are not
    /// equally safe to drop: a lost "mute" just means a few extra notifications, but a lost
    /// "unmute" leaves this phone silent for the full backstop window with no way to notice. The
    /// app's foreground sync heals it eventually — "eventually" is not good enough for a security
    /// app, so clears get more attempts than mutes.
    static func syncFocusSnooze(_ until: Double) async {
        let clearing = until <= 0
        let attempts = clearing ? 3 : 1
        for attempt in 0..<attempts {
            if await postFocusSnooze(until) { return }
            // Back off before retrying; the extension's runtime is short, so keep this bounded
            // and small (1s, 3s) rather than an open-ended retry loop iOS would just suspend.
            if attempt < attempts - 1 {
                let delay = UInt64(attempt == 0 ? 1_000_000_000 : 3_000_000_000)
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    /// One POST attempt. Returns true only on a 2xx — anything else is worth retrying.
    private static func postFocusSnooze(_ until: Double) async -> Bool {
        let defaults = UserDefaults(suiteName: ApexAppGroup.identifier)
        let relayURL = nonEmpty(defaults?.string(forKey: "apex.relayURL")) ?? RelayConfig.defaultURL
        guard let pairing = nonEmpty(defaults?.string(forKey: "apex.pairingCode")) ?? nonEmpty(RelayConfig.defaultPairingCode),
              let token = nonEmpty(defaults?.string(forKey: "apex.apnsDeviceToken"))
        else { return false }

        var trimmed = relayURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + "/v1/device-prefs"),
              url.scheme == "https", url.host != nil else { return false }

        // Keys must match the main app's DevicePrefsBody (snake_case). `prefs` is deliberately
        // OMITTED, not empty: the relay treats an absent blob as "don't touch", so this extension
        // can't wipe the camera mutes / quiet hours / triggers it has no way to reconstruct.
        let body: [String: Any] = [
            "device_token": token,
            "pairing_code": pairing,
            "focus_snoozed_until": until
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

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
