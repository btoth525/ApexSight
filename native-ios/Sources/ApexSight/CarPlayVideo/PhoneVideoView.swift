import AVKit
import SwiftUI
import UIKit

/// The phone-side player for a feed: the same canvas the car uses, with Picture in Picture that
/// keeps the stream going when the app backgrounds (sample-buffer PiP for MJPEG / H.264 /
/// mirror, player-layer PiP for HLS / MP4).
struct PhoneVideoView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PhoneVideoViewController { PhoneVideoViewController() }
    func updateUIViewController(_ uiViewController: PhoneVideoViewController, context: Context) {}
}

@MainActor
final class PhoneVideoViewController: UIViewController {
    private let canvas = VideoCanvasView()
    private var pip: AVPictureInPictureController?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        canvas.frame = view.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(canvas)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        UIApplication.shared.isIdleTimerDisabled = true
        CarVideoSession.shared.attach(canvas)
        if CarVideoSession.shared.source == .none { CarVideoSession.shared.playLast() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
        // Keep the session alive while PiP has it; only detach when the screen is really leaving.
        if pip?.isPictureInPictureActive != true { CarVideoSession.shared.detach(canvas) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard pip == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        // Muted video: mix with the user's audio rather than taking the session.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: canvas.displayLayer,
                                                                 playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = true
        pip = controller
    }
}

// Live-stream semantics: no timeline, "play" restarts the feed, "pause" stops it.
extension PhoneVideoViewController: AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in playing ? CarVideoSession.shared.restart() : CarVideoSession.shared.stop() }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated { !CarVideoSession.shared.isStreaming }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                skipByInterval skipInterval: CMTime) async {}

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in
            // PiP ended and the screen is gone → release the canvas so the session isn't kept alive by it.
            if self.view.window == nil { CarVideoSession.shared.detach(self.canvas) }
        }
    }
}
