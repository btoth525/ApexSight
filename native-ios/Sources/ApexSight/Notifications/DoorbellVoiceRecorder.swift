import AVFoundation

/// Records mic audio to an m4a file for the doorbell soundboard: push-to-talk (record while the
/// Talk button is held, send on release) and saving custom clips. The relay transcodes m4a to the
/// doorbell's audio format, so we record a compact AAC file here.
@MainActor
final class DoorbellVoiceRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?

    /// Ask for mic permission up front so the first hold-to-talk doesn't get clipped by the prompt.
    static func requestPermission() {
        AVAudioApplication.requestRecordPermission { _ in }
    }

    func start() {
        stop()
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? session.setActive(true)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("apex-rec-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        recorder = try? AVAudioRecorder(url: url, settings: settings)
        recorder?.record()
        fileURL = url
        isRecording = recorder != nil
    }

    /// Stop recording and return the file + bytes, or nil if it was too short/empty to be speech.
    func stopAndData() -> (url: URL, data: Data)? {
        recorder?.stop()
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        guard let url = fileURL, let data = try? Data(contentsOf: url), data.count > 1500 else { return nil }
        return (url, data)
    }

    func stop() {
        recorder?.stop()
        recorder = nil
        isRecording = false
    }
}
