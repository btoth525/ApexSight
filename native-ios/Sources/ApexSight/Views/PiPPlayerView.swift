import SwiftUI
import AVKit

/// AVPlayerViewController wrapper that enables Picture-in-Picture and native transport controls.
/// Used for live streams and clip playback so video keeps running when the app backgrounds.
struct PiPPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    var showsControls = true

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.showsPlaybackControls = showsControls
        controller.videoGravity = .resizeAspect
        controller.view.backgroundColor = .black
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
        controller.showsPlaybackControls = showsControls
    }
}
