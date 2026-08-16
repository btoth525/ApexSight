import Foundation

/// Talks to the ApexSight push relay's public API. Registers this device's APNs
/// token under the household pairing code so the relay knows where to deliver
/// pushes forwarded by the Home Assistant bridge.
enum RelayClient {
    enum RelayError: LocalizedError {
        case invalidURL
        case server(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Enter a valid relay URL (https://…)."
            case let .server(code, msg): return "Relay error \(code): \(msg)"
            }
        }
    }

    private struct RegisterBody: Encodable {
        let device_token: String
        let pairing_code: String
        let environment: String
        let platform: String
        let device_name: String   // user-set phone name → per-phone HA entity (relay ≥ 1.7.0)
    }

    private struct UnregisterBody: Encodable {
        let device_token: String
    }

    private struct RegisterVoIPBody: Encodable {
        let voip_token: String
        let pairing_code: String
        let environment: String
    }

    private struct TestBody: Encodable {
        let device_token: String
        let environment: String
    }

    private struct StyleBody: Encodable {
        let pairing_code: String
        let style: NotificationStyle
    }

    private struct AICamerasBody: Encodable {
        let pairing_code: String
        let disabled: [String]
    }
    private struct MutedCamerasBody: Encodable {
        let pairing_code: String
        let muted: [String]
    }
    // Per-device SOFT prefs wire format. Field names MUST match the relay's gate.would_deliver
    // reads exactly — a mismatch fails open (mutes nothing) and the feature silently no-ops.
    // Soft-only: NO `disarmed` / `snoozed_until` here (those stay household via the gate).
    private struct DevicePrefsBlob: Encodable {
        let cameras_disabled: [String]
        let objects_disabled: [String]
        let zones_disabled: [String]
        let camera_snoozes: [String: Double]
        let quiet_hours: QuietHours
        let tz_offset: Int
        let triggers: [TriggerBlob]
        struct QuietHours: Encodable { let enabled: Bool; let start: Int; let end: Int }
        struct TriggerBlob: Encodable {
            let name: String
            let cameras: [String]
            let labels: [String]
            let required_zones: [String]
            let min_confidence: Double
            let respect_quiet_hours: Bool
            let enabled: Bool
        }
    }
    private struct DevicePrefsBody: Encodable {
        let device_token: String
        let pairing_code: String
        let device_name: String   // keeps the per-phone HA entity name fresh on the foreground sync
        let prefs: DevicePrefsBlob
        /// ALWAYS 0 — a tombstone, not a value.
        ///
        /// The Focus filter is gone (see `SharedActionIntents`), but the relay stores this mute per
        /// device under its own `focus:<token>` key, and `gate.py` still suppresses pushes while it
        /// is in the future. Simply no longer writing it would leave whatever was last written in
        /// place — a phone could stay silent for hours after the update, which is the exact failure
        /// removing the feature is meant to end. Sending an explicit 0 on every sync clears it, and
        /// keeps clearing it, so a mute written by an older build on any device heals itself.
        let focus_snoozed_until: Double
    }

    private struct GateBody: Encodable {
        let pairing_code: String
        let disarmed: Bool
        let snoozed_until: Double   // epoch seconds; 0 = not snoozed
        let by: String              // this device's name, so the banner can say WHO silenced it
    }

    private struct RecapBody: Encodable {
        let pairing_code: String
        let enabled: Bool
        let hour: Int
        let minute: Int
        let tz_offset: Int
    }

    private struct ActivityBody: Encodable {
        let pairing_code: String
        let token: String
        let environment: String
        let kind: String   // "start" = push-to-start token
    }

    private struct SetModeBody: Encodable {
        let mode: String            // "home" (disarm) | "away" | "night"
        let device_token: String    // → who armed
        let pairing_code: String
        let code: String            // Alarmo code; required to disarm, empty to arm
    }

    /// Current house mode as the relay mirrors it from Alarmo, for the app to reflect. `armedBy`
    /// is who last requested a change (for display). nil if the relay is unreachable.
    struct HouseModeStatus: Decodable {
        let mode: String
        let mutes: [String]?           // cameras this mode silences — used to filter the app feeds
        let armed_by: ArmedBy?
        let map: [String: [String]]?   // full per-mode mute matrix (household custom map or defaults)
        let map_custom: Bool?          // true when the household edited the matrix in-app
        let cameras: [String]?         // camera roster last synced with the map
        let snoozed_until: Double?     // household snooze (epoch; present when pairing_code sent)
        let disarmed: Bool?            // household notifications disarmed (present when pairing_code sent)
        let gate_by: String?           // device that set the active snooze/disarm (relay ≥ 1.16.0)
        let gate_at: Double?           // when it was set (epoch); absent on older relays
        struct ArmedBy: Decodable { let by: String?; let mode: String?; let ts: Double? }
    }

    private struct ModeMapBody: Encodable {
        let pairing_code: String
        let mutes: [String: [String]]  // mode → cameras muted in that mode (household-wide)
        let cameras: [String]          // full roster so the relay/bridge can flip unmuted cams ON
        let by: String                 // this phone's name, for the "last edited by" trail
        let reset: Bool
    }

    /// Result of a `/healthz` probe used for the green/red status dot.
    struct Health: Decodable {
        let ok: Bool
        let apns_configured: Bool?
    }

    /// Returns the relay's health, or nil if it's unreachable.
    static func health(relayURL: String) async -> Health? {
        var trimmed = relayURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + "/healthz") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            guard ok else { return nil }
            return try? JSONDecoder().decode(Health.self, from: data)
        } catch {
            return nil
        }
    }

    static func register(relayURL: String, deviceToken: String, pairingCode: String,
                         environment: String, deviceName: String = "") async throws {
        let body = RegisterBody(
            device_token: deviceToken,
            pairing_code: pairingCode,
            environment: environment,
            platform: "ios",
            device_name: deviceName
        )
        try await post(relayURL: relayURL, path: "/v1/register", body: body)
    }

    static func unregister(relayURL: String, deviceToken: String) async throws {
        try await post(relayURL: relayURL, path: "/v1/unregister", body: UnregisterBody(device_token: deviceToken))
    }

    /// Register this device's PushKit VoIP token so the relay can ring it (CallKit) on a doorbell press.
    static func registerVoIP(relayURL: String, voipToken: String, pairingCode: String, environment: String) async throws {
        try await post(relayURL: relayURL, path: "/v1/register-voip",
                       body: RegisterVoIPBody(voip_token: voipToken, pairing_code: pairingCode.uppercased(), environment: environment))
    }

    /// Tell the relay which cameras have AI descriptions in notifications turned OFF, so the
    /// HomeKit-style GenAI-description follow-up is only sent for the cameras the user enabled.
    static func syncAICameras(relayURL: String, pairingCode: String, disabled: [String]) async throws {
        try await post(relayURL: relayURL, path: "/v1/ai-cameras",
                       body: AICamerasBody(pairing_code: pairingCode, disabled: disabled))
    }

    /// Tell the relay which cameras have notifications turned OFF entirely, so app-closed pushes
    /// for those cameras are suppressed at the relay — the in-app per-camera toggle otherwise only
    /// gates foreground delivery, letting closed-app pushes for a muted camera slip through.
    static func syncMutedCameras(relayURL: String, pairingCode: String, muted: [String]) async throws {
        try await post(relayURL: relayURL, path: "/v1/muted-cameras",
                       body: MutedCamerasBody(pairing_code: pairingCode, muted: muted))
    }

    /// Sync THIS device's soft notification prefs (per-camera/object/zone mutes, quiet hours,
    /// per-camera snoozes, triggers) to the relay keyed by device token, so app-closed pushes are
    /// gated per device exactly as the foreground app. Soft-only — Disarm/Snooze-all stay household
    /// via `syncGate`. Converts the app's `*Enabled` allow-maps to the relay's disabled-lists.
    static func syncDevicePrefs(relayURL: String, deviceToken: String, pairingCode: String,
                                deviceName: String = "",
                                preferences: NotificationPreferences,
                                triggers: [NotificationTrigger]) async throws {
        let blob = DevicePrefsBlob(
            cameras_disabled: preferences.cameraEnabled.filter { !$0.value }.map(\.key),
            objects_disabled: preferences.objectEnabled.filter { !$0.value }.map(\.key),
            zones_disabled: preferences.zoneEnabled.filter { !$0.value }.map(\.key),
            camera_snoozes: preferences.snoozedUntil,
            quiet_hours: .init(
                enabled: preferences.quietHoursEnabled,
                start: preferences.quietHoursStartHour * 60 + preferences.quietHoursStartMinute,
                end: preferences.quietHoursEndHour * 60 + preferences.quietHoursEndMinute
            ),
            tz_offset: TimeZone.current.secondsFromGMT(),
            triggers: triggers.map {
                DevicePrefsBlob.TriggerBlob(
                    name: $0.name, cameras: $0.cameras, labels: $0.labels,
                    required_zones: $0.requiredZones, min_confidence: $0.minConfidence,
                    respect_quiet_hours: $0.respectQuietHours, enabled: $0.enabled
                )
            }
        )
        try await post(relayURL: relayURL, path: "/v1/device-prefs",
                       body: DevicePrefsBody(device_token: deviceToken, pairing_code: pairingCode,
                                             device_name: deviceName, prefs: blob,
                                             focus_snoozed_until: 0))
    }

    /// Asks the relay to send a test push to this device.
    static func sendTest(relayURL: String, deviceToken: String, environment: String) async throws {
        try await post(relayURL: relayURL, path: "/v1/test", body: TestBody(device_token: deviceToken, environment: environment))
    }

    /// Saves this household's notification style on the relay, so app-closed pushes
    /// are rendered the way the user configured in the app.
    static func syncStyle(relayURL: String, pairingCode: String, style: NotificationStyle) async throws {
        try await post(relayURL: relayURL, path: "/v1/style", body: StyleBody(pairing_code: pairingCode, style: style))
    }

    /// Tells the relay the household's current arm/snooze state so app-closed pushes
    /// are suppressed while disarmed or snoozed — keeping the relay consistent with
    /// the in-app delivery gate.
    static func syncGate(relayURL: String, pairingCode: String, disarmed: Bool, snoozedUntil: Double) async throws {
        try await post(relayURL: relayURL, path: "/v1/gate",
                       body: GateBody(pairing_code: pairingCode, disarmed: disarmed,
                                      snoozed_until: snoozedUntil, by: DeviceTokenStore.deviceName))
    }

    /// Saves the Daily Recap schedule on the relay so the summary is delivered at the
    /// chosen local time even when the app is fully closed. `tzOffset` is seconds from GMT.
    static func syncRecap(relayURL: String, pairingCode: String, enabled: Bool, hour: Int, minute: Int, tzOffset: Int) async throws {
        try await post(relayURL: relayURL, path: "/v1/recap",
                       body: RecapBody(pairing_code: pairingCode, enabled: enabled, hour: hour, minute: minute, tz_offset: tzOffset))
    }

    /// Registers this device's Live Activity push-to-start token so the relay can start an
    /// incident Live Activity on the Lock Screen even when the app is fully closed.
    static func registerActivity(relayURL: String, pairingCode: String, token: String, environment: String, kind: String = "start") async throws {
        try await post(relayURL: relayURL, path: "/v1/activity/register",
                       body: ActivityBody(pairing_code: pairingCode, token: token, environment: environment, kind: kind))
    }

    /// Requests a house-mode change. Arming rides the pairing code; disarming (mode "home") must
    /// carry the Alarmo `code`, which HA/Alarmo validates server-side. Throws RelayError.server on a
    /// relay-level rejection (e.g. 403 when a disarm arrives with no code).
    static func setMode(relayURL: String, deviceToken: String, pairingCode: String,
                        mode: String, code: String = "") async throws {
        try await post(relayURL: relayURL, path: "/v1/set-mode",
                       body: SetModeBody(mode: mode, device_token: deviceToken,
                                         pairing_code: pairingCode, code: code))
    }

    /// Reads the current house mode from the relay so the app (and a partner's app) reflect it.
    /// Passing the household `pairingCode` also returns the household gate (snooze/disarm) so the
    /// app can SHOW when notifications are silenced instead of dropping them invisibly.
    static func getMode(relayURL: String, pairingCode: String = "") async -> HouseModeStatus? {
        var trimmed = relayURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        var path = "/v1/mode"
        if !pairingCode.isEmpty,
           let encoded = pairingCode.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?pairing_code=\(encoded)"
        }
        guard let url = URL(string: trimmed + path) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            guard ok else { return nil }
            return try? JSONDecoder().decode(HouseModeStatus.self, from: data)
        } catch {
            return nil
        }
    }

    /// Save the household's per-mode camera alert matrix (Settings → Notifications → House Mode
    /// Alerts). Household-wide: every phone on the pairing code follows the same map, and the
    /// bridge mirrors it into Frigate's per-camera alert switches so HA agrees too.
    static func setModeMap(relayURL: String, pairingCode: String, mutes: [String: [String]],
                           cameras: [String], by: String, reset: Bool = false) async throws {
        try await post(relayURL: relayURL, path: "/v1/mode-map",
                       body: ModeMapBody(pairing_code: pairingCode, mutes: mutes,
                                         cameras: cameras, by: by, reset: reset))
    }

    private static func post<T: Encodable>(relayURL: String, path: String, body: T) async throws {
        var trimmed = relayURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        // Require https specifically (not just "some scheme") — the relay carries the pairing
        // code and disarm code, unlike the user-supplied Frigate host, which legitimately needs
        // plain http for LAN/DDNS setups ATS's own exception (see project.yml) already covers
        // for that host only. Defense in depth alongside the ATS exception domain.
        guard let base = URL(string: trimmed), base.scheme == "https", base.host != nil,
              let url = URL(string: trimmed + path) else { throw RelayError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw RelayError.server(code, msg)
        }
    }

    // MARK: - Doorbell talkback (play audio to the Aqara doorbell speaker)

    /// A saved talkback preset ("soundboard" clip) stored on the relay.
    struct DoorbellClip: Decodable, Identifiable, Hashable {
        let slug: String
        let name: String
        var id: String { slug }
    }

    private struct DoorbellSlugBody: Encodable { let pairing_code: String; let slug: String }

    private static func base(_ relayURL: String) -> String {
        var t = relayURL.trimmingCharacters(in: .whitespaces)
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }

    /// Whether talkback is configured on the relay and the doorbell is reachable. NB: this opens a
    /// voice session on the camera to probe — call it once (on view appear), never poll, and never
    /// during active playback (one voice session at a time). Returns nil on network failure.
    static func doorbellStatus(relayURL: String, pairingCode: String) async -> (configured: Bool, reachable: Bool)? {
        struct Status: Decodable { let configured: Bool; let reachable: Bool }
        var comps = URLComponents(string: base(relayURL) + "/v1/doorbell/status")
        comps?.queryItems = [URLQueryItem(name: "pairing_code", value: pairingCode)]
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0),
              let s = try? JSONDecoder().decode(Status.self, from: data) else { return nil }
        return (s.configured, s.reachable)
    }

    /// List the saved talkback presets.
    static func listDoorbellClips(relayURL: String, pairingCode: String) async -> [DoorbellClip] {
        struct Resp: Decodable { let clips: [DoorbellClip] }
        var comps = URLComponents(string: base(relayURL) + "/v1/doorbell/clips")
        comps?.queryItems = [URLQueryItem(name: "pairing_code", value: pairingCode)]
        guard let url = comps?.url else { return [] }
        var req = URLRequest(url: url); req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0),
              let r = try? JSONDecoder().decode(Resp.self, from: data) else { return [] }
        return r.clips
    }

    /// LIVE hold-to-talk session: tells the relay to pull the mic stream the app just published
    /// into go2rtc (`apex_talkback`) and pipe it to the doorbell speaker. BLOCKS for the duration
    /// of the talk — the relay returns when the mic publish ends (talk-button release) — so call
    /// it from a fire-and-forget Task with the long timeout it carries. Throws on 404 (add-on too
    /// old), 409 (no stream landed / another clip busy), 5xx (camera/ffmpeg failure).
    static func doorbellTalkLive(relayURL: String, pairingCode: String) async throws {
        struct Body: Encodable { let pairing_code: String }
        var trimmed = relayURL.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let baseURL = URL(string: trimmed), baseURL.scheme != nil, baseURL.host != nil,
              let url = URL(string: trimmed + "/v1/doorbell/talk-live") else { throw RelayError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(pairing_code: pairingCode))
        request.timeoutInterval = 150   // ≥ the relay's 120s per-hold backstop

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw RelayError.server(code, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Play a saved preset at the door.
    static func playSavedDoorbellClip(relayURL: String, pairingCode: String, slug: String) async throws {
        try await post(relayURL: relayURL, path: "/v1/doorbell/play",
                       body: DoorbellSlugBody(pairing_code: pairingCode, slug: slug))
    }

    /// Delete a saved preset.
    static func deleteDoorbellClip(relayURL: String, pairingCode: String, slug: String) async throws {
        try await post(relayURL: relayURL, path: "/v1/doorbell/delete",
                       body: DoorbellSlugBody(pairing_code: pairingCode, slug: slug))
    }

    /// Upload an audio clip and play it at the door immediately; optionally save it as a preset
    /// (pass a non-empty `saveAs` name). Any format ffmpeg reads works — the relay transcodes.
    static func uploadDoorbellClip(relayURL: String, pairingCode: String, audio: Data,
                                   filename: String, saveAs: String = "") async throws {
        guard let url = URL(string: base(relayURL) + "/v1/doorbell/clip") else { throw RelayError.invalidURL }
        let boundary = "apex-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 45
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Quotes/CR/LF in a filename or preset name would corrupt the multipart framing — strip
        // them (the value itself, sent in the body, keeps its normal characters otherwise).
        func headerSafe(_ s: String) -> String {
            s.replacingOccurrences(of: "\"", with: "'")
                .components(separatedBy: .newlines).joined(separator: " ")
        }
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value.components(separatedBy: .newlines).joined(separator: " "))\r\n".data(using: .utf8)!)
        }
        field("pairing_code", pairingCode)
        if !saveAs.isEmpty { field("save_as", saveAs) }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(headerSafe(filename))\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw RelayError.server(code, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
