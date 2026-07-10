import AVFoundation

/// On-device text-to-speech for the doorbell soundboard. Synthesizes text with the nicest available
/// iOS voice and writes it to a CAF file (uncompressed LPCM) we upload to the relay — which
/// transcodes to the doorbell's audio format. Fully offline: no cloud, no Home Assistant needed.
enum DoorbellSpeech {
    /// The best-quality voice for the current language (premium/enhanced if the user installed one).
    static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let lang = AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let matching = voices.filter { $0.language == lang }
        let pool = matching.isEmpty ? voices : matching
        return pool.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: lang)
    }

    /// Voices the user can pick from — same language family, best (neural premium/enhanced) first.
    static func selectableVoices() -> [AVSpeechSynthesisVoice] {
        let prefix = String(AVSpeechSynthesisVoice.currentLanguageCode().prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .sorted { a, b in
                a.quality.rawValue != b.quality.rawValue
                    ? a.quality.rawValue > b.quality.rawValue
                    : a.name < b.name
            }
    }

    /// Resolve a stored voice identifier, falling back to the best available voice.
    static func voice(id: String?) -> AVSpeechSynthesisVoice? {
        if let id, !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return preferredVoice()
    }

    static func qualityName(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium:  return "Premium"
        case .enhanced: return "Enhanced"
        default:        return "Standard"
        }
    }

    /// Synthesize `text` to a CAF file and return its URL (the caller deletes it after upload).
    /// Returns nil on empty text or synthesis failure.
    static func synthesize(_ text: String, voice: AVSpeechSynthesisVoice? = nil) async -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return await SpeechWriter().write(trimmed, voice: voice ?? preferredVoice())
    }
}

/// Owns the synthesizer + output file for one synthesis. A class so the `write` callback (which runs
/// off an arbitrary queue) captures a single reference rather than the non-Sendable synth directly;
/// the instance stays alive for the whole `await` because `synthesize` holds it across the call.
///
/// Notes on `AVSpeechSynthesizer.write` (where it bites people): buffers arrive in the synth's native
/// Float32 format, so we build the `AVAudioFile` from the first non-empty buffer's `processingFormat`
/// and write LPCM — never AAC/m4a. The first/last callback buffer is often `frameLength == 0`; the
/// trailing empty buffer signals completion.
private final class SpeechWriter: @unchecked Sendable {
    private let synth = AVSpeechSynthesizer()
    private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("apex-say-\(UUID().uuidString).caf")
    private var file: AVAudioFile?
    private var wroteFrames = false
    private var resumed = false
    private var continuation: CheckedContinuation<URL?, Never>?

    func write(_ text: String, voice: AVSpeechSynthesisVoice?) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            continuation = cont
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            synth.write(utterance) { [weak self] buffer in self?.handle(buffer) }
            // In case the trailing empty buffer never arrives, resolve on what we have.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self else { return }
                self.finish(self.wroteFrames ? self.url : nil)
            }
        }
    }

    private func handle(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 {
            if wroteFrames {
                finish(url)   // trailing empty buffer = done
            } else {
                // Empty with nothing written: either the LEADING empty buffer (real audio follows)
                // or a failed synthesis that will never produce frames. Give it a short grace
                // window instead of stalling out the full 15s timeout.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    guard let self, !self.wroteFrames else { return }
                    self.finish(nil)
                }
            }
            return
        }
        if file == nil {
            file = try? AVAudioFile(forWriting: url, settings: pcm.format.settings,
                                    commonFormat: pcm.format.commonFormat,
                                    interleaved: pcm.format.isInterleaved)
            if file == nil { finish(nil); return }
        }
        if (try? file?.write(from: pcm)) != nil { wroteFrames = true }
    }

    private func finish(_ result: URL?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.resumed else { return }
            self.resumed = true
            self.continuation?.resume(returning: result)
            self.continuation = nil
        }
    }
}
