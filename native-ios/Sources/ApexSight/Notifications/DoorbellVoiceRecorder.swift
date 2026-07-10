import AVFoundation

/// Records mic audio to an m4a file for the doorbell soundboard: push-to-talk (record while the
/// Talk button is held, send on release) and saving custom clips. The relay transcodes m4a to the
/// doorbell's audio format, so we record a compact AAC file here.
///
/// Audio-session care: recording runs DURING a live call (the doorbell player is rendering audio),
/// so this switches the shared session to `.playAndRecord` for the hold and restores the previous
/// category afterward — and never calls `setActive(false)`, which would kill the call's live audio
/// mid-conversation.
@MainActor
final class DoorbellVoiceRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var previousCategory: AVAudioSession.Category?
    private var previousMode: AVAudioSession.Mode?
    private var previousOptions: AVAudioSession.CategoryOptions = []
    private var autoStopTask: Task<Void, Never>?
    /// Backstop: no push-to-talk hold should run longer than this — a gesture that was cancelled
    /// without release (List scroll steal, view teardown) must never leave a hot mic.
    static let maxSeconds: TimeInterval = 30

    /// Ask for mic permission up front so the first hold-to-talk doesn't get clipped by the prompt.
    static func requestPermission() {
        AVAudioApplication.requestRecordPermission { _ in }
    }

    func start() {
        stop()
        let session = AVAudioSession.sharedInstance()
        previousCategory = session.category
        previousMode = session.mode
        previousOptions = session.categoryOptions
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
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
        // record() returning false (mic permission denied, session refused) must show as NOT
        // recording — never let the UI pantomime a hold that captures nothing.
        let recording = recorder?.record() == true
        if !recording { recorder = nil }
        fileURL = recording ? url : nil
        isRecording = recording
        if recording {
            autoStopTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.maxSeconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.stop()   // stuck hold (cancelled gesture) — stop + discard, never send
            }
        } else {
            restoreSession()
        }
    }

    /// Stop recording and return the file + bytes, or nil if it was too short/empty to be speech.
    func stopAndData() -> (url: URL, data: Data)? {
        autoStopTask?.cancel(); autoStopTask = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        restoreSession()
        guard let url = fileURL, let data = try? Data(contentsOf: url), data.count > 1500 else { return nil }
        fileURL = nil
        return (url, data)
    }

    /// Stop and discard (view dismissed / gesture cancelled / auto-stop backstop).
    func stop() {
        autoStopTask?.cancel(); autoStopTask = nil
        guard recorder != nil || isRecording else { return }
        recorder?.stop()
        recorder = nil
        isRecording = false
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
        restoreSession()
    }

    /// Put the shared session back the way the call/player had it. No `setActive(false)` — other
    /// audio (the live doorbell feed) is still using the session.
    private func restoreSession() {
        guard let category = previousCategory, let mode = previousMode else { return }
        try? AVAudioSession.sharedInstance().setCategory(category, mode: mode, options: previousOptions)
        previousCategory = nil
        previousMode = nil
        previousOptions = []
    }
}
