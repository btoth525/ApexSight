import Foundation

/// Drives the doorbell "soundboard" — speak typed text (on-device TTS), play/save/delete preset
/// clips, and push-to-talk — all through the relay's talkback endpoints. Reads the relay URL +
/// pairing code from the shared token store, so it works anywhere the app is paired.
@MainActor
final class DoorbellSoundboard: ObservableObject {
    /// Talkback is configured on the relay AND the doorbell answered a probe. Probed at most once
    /// per launch (the probe opens a brief voice session on the camera — we never poll it).
    @Published var available = false
    @Published var checked = false
    @Published var clips: [RelayClient.DoorbellClip] = []
    @Published var busy = false
    @Published var status: String?

    private static var probedThisLaunch = false
    private static var cachedAvailable = false

    private var relayURL: String { DeviceTokenStore.relayURL }
    private var pairing: String { DeviceTokenStore.ensurePairingCode() }
    private var ready: Bool { !relayURL.isEmpty && !pairing.isEmpty }

    /// Probe availability once per launch, and (re)load the preset list. Call on view appear only.
    func refresh() async {
        guard ready else { checked = true; return }
        if DoorbellSoundboard.probedThisLaunch {
            available = DoorbellSoundboard.cachedAvailable
        } else if let s = await RelayClient.doorbellStatus(relayURL: relayURL, pairingCode: pairing) {
            available = s.configured && s.reachable
            DoorbellSoundboard.cachedAvailable = available
            DoorbellSoundboard.probedThisLaunch = true
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
    func say(_ text: String, voiceID: String? = nil, saveAs: String = "") async {
        guard ready,
              let url = await DoorbellSpeech.synthesize(text, voice: DoorbellSpeech.voice(id: voiceID))
        else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        await sendData((try? Data(contentsOf: url)) ?? Data(), filename: "say.caf", saveAs: saveAs)
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
