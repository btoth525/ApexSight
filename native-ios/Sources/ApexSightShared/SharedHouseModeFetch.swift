import Foundation

/// Fetches the live house mode straight from the relay and updates the app-group mirror
/// (`SharedHouseMode`) — so the Lock Screen widget and Control Center can show the TRUE mode even
/// when the main app hasn't run in hours. Foundation-only on purpose: this compiles into the
/// widget extension, which can't reach the app's networking stack.
///
/// Called from (a) the widget's timeline provider (each timeline reload re-verifies against the
/// relay) and (b) the app's silent-push handler (the relay wakes every phone the moment the mode
/// changes). Best-effort with a short timeout — on any failure the cached mirror stands.
public enum SharedHouseModeFetch {
    /// GET /v1/mode, update `SharedHouseMode`, and return the fresh mode ("" on failure).
    /// `reloadingSurfaces`: pass false when calling FROM the widget's own timeline provider — the
    /// fresh value is already going into the entry, and reloadAllTimelines from inside a timeline
    /// build would loop (and burn the widget refresh budget). The app's silent-push path passes
    /// true so a mode change repaints every surface.
    @discardableResult
    public static func refresh(reloadingSurfaces: Bool = true) async -> String {
        let defaults = UserDefaults(suiteName: ApexAppGroup.identifier)
        var relayURL = defaults?.string(forKey: "apex.relayURL") ?? ""
        if relayURL.trimmingCharacters(in: .whitespaces).isEmpty { relayURL = RelayConfig.defaultURL }
        var trimmed = relayURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        // Send the household pairing code so the relay can authenticate this read. GET /v1/mode
        // exposes live occupancy (home/away), armed_by, and the camera roster, so it should be
        // gated; the widget's timeline provider and the silent-push handler both reach it through
        // here, so they must present the code too. The code is available to this (widget-linked)
        // Foundation file via the app-group mirror, falling back to the baked household default.
        guard var comps = URLComponents(string: trimmed + "/v1/mode"), comps.scheme != nil, comps.host != nil else { return "" }
        let pairing = defaults?.string(forKey: "apex.pairingCode") ?? RelayConfig.defaultPairingCode
        if !pairing.isEmpty { comps.queryItems = [URLQueryItem(name: "pairing_code", value: pairing)] }
        guard let url = comps.url else { return "" }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }

        let mode = (obj["mode"] as? String) ?? ""
        guard ["home", "night", "away"].contains(mode) else { return "" }
        let by = ((obj["armed_by"] as? [String: Any])?["by"] as? String) ?? ""
        let changed = SharedHouseMode.mode != mode
        SharedHouseMode.mode = mode
        if !by.isEmpty { SharedHouseMode.armedBy = by }
        // The SAME response carries the cameras this mode silences, so refresh the mute mirror here
        // too. Without it only the app process ever writes the list, and a mode change while the app
        // is closed would leave the widget/Watch/Siri feed filtering by the previous mode's mutes —
        // `SharedHouseMode.mutedCameras` would then correctly ignore it and show everything, but
        // that is the safe degradation, not the right answer. Reading it here makes the mirror true.
        // Absent/malformed → clear the list for this mode, which fails OPEN.
        SharedHouseMode.setMutedCameras((obj["mutes"] as? [String]) ?? [], for: mode)
        if changed && reloadingSurfaces { ApexSurfaceRefresh.reload() }
        return mode
    }
}
