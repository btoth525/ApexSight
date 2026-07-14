import Foundation

/// Drives the doorbell "soundboard" — speak typed text (on-device TTS), play/save/delete preset
/// clips, and push-to-talk — all through the relay's talkback endpoints. Reads the relay URL +
/// pairing code from the shared token store, so it works anywhere the app is paired.
@MainActor
final class DoorbellSoundboard: ObservableObject {
    /// Talkback is configured on the relay AND the doorbell answered a reachability check (a plain
    /// TCP probe on the relay side — non-invasive, safe to re-run on every view appear, so fixing
    /// the add-on config shows up without relaunching the app).
    @Published var available = false
    @Published var checked = false
    @Published var clips: [RelayClient.DoorbellClip] = []
    @Published var busy = false
    @Published var status: String?

    private var relayURL: String { DeviceTokenStore.relayURL }
    private var pairing: String { DeviceTokenStore.ensurePairingCode() }
    private var ready: Bool { !relayURL.isEmpty && !pairing.isEmpty }

    /// Check availability and (re)load the preset list. Call on view appear.
    func refresh() async {
        guard ready else { checked = true; return }
        if let s = await RelayClient.doorbellStatus(relayURL: relayURL, pairingCode: pairing) {
            available = s.configured && s.reachable
        }
        clips = await RelayClient.listDoorbellClips(relayURL: relayURL, pairingCode: pairing)
        checked = true
    }

    /// Reload just the preset list (no camera probe) — safe after add/delete.
    func reloadClips() async {
        guard ready else { return }
        clips = await RelayClient.listDoorbellClips(relayURL: relayURL, pairingCode: pairing)
    }

    /// Speak typed text at the door via on-device TTS. Optionally choose a voice + save as a preset.
    /// Every failure surfaces in `status` — a tap that makes no sound must never be silent in the UI.
    func say(_ text: String, voiceID: String? = nil, saveAs: String = "") async {
        guard ready else { return }
        busy = true
        status = nil
        guard let url = await DoorbellSpeech.synthesize(text, voice: DoorbellSpeech.voice(id: voiceID)) else {
            busy = false
            status = "Couldn't synthesize speech — try a different voice."
            return
        }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            busy = false
            status = "Couldn't read the synthesized audio."
            return
        }
        busy = false
        await sendData(data, filename: "say.caf", saveAs: saveAs)
    }

    /// Play a saved preset at the door.
    func playClip(_ slug: String) async {
        guard ready else { return }
        await run { try await RelayClient.playSavedDoorbellClip(relayURL: self.relayURL, pairingCode: self.pairing, slug: slug) }
    }

    /// Upload raw audio (recording / imported file) → play now, optionally save.
    func sendData(_ data: Data, filename: String, saveAs: String = "") async {
        guard ready, !data.isEmpty else { return }
        await run {
            try await RelayClient.uploadDoorbellClip(relayURL: self.relayURL, pairingCode: self.pairing,
                                                     audio: data, filename: filename, saveAs: saveAs)
        }
        if !saveAs.isEmpty { await reloadClips() }
    }

    /// LIVE hold-to-talk session. The caller has already started publishing the mic into go2rtc's
    /// `apex_talkback`; this tells the relay to pipe that stream to the doorbell speaker, and
    /// stays awaiting until the talk ends (mic publish stops → stream EOFs → relay returns).
    /// Failures surface in `status` with actionable copy — never a silent dead talk button.
    func talkLive() async {
        guard ready else { return }
        status = nil
        do {
            try await RelayClient.doorbellTalkLive(relayURL: relayURL, pairingCode: pairing)
        } catch {
            if case RelayClient.RelayError.server(let code, _) = error, code == 404 {
                status = "Live talk needs the ApexSight Push add-on v1.12+ — update it in Home Assistant."
            } else if case RelayClient.RelayError.server(409, _) = error {
                status = "The door speaker is busy — try again in a moment."
            } else {
                status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// Delete a saved preset.
    func delete(_ slug: String) async {
        guard ready else { return }
        try? await RelayClient.deleteDoorbellClip(relayURL: relayURL, pairingCode: pairing, slug: slug)
        await reloadClips()
    }

    private func run(_ op: @escaping () async throws -> Void) async {
        busy = true
        status = nil
        defer { busy = false }
        do {
            try await op()
        } catch {
            status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
