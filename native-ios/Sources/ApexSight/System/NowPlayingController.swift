import Foundation
import AVFoundation
import MediaPlayer

/// Publishes the **active full-screen camera/clip player** to the system Now Playing surfaces —
/// Lock Screen, Control Center, the Dynamic Island, and CarPlay — so the user gets transport
/// controls for a live camera or a recording without opening the app (iOS 27 "A1" feature).
///
/// Built on `MPNowPlayingSession` (MediaPlayer, iOS 16+), which wraps the app's own `AVPlayer`
/// and auto-publishes playback state. Chosen over the new `NowPlaying.MediaSession<Representable>`
/// framework on purpose: this path is simpler, more broadly supported, and maps a single AVPlayer
/// straight onto the system UI — exactly what a camera viewer needs.
///
/// Single active session at a time. Only the full-screen viewer / clip player attach here — the
/// multi-camera wall does **not**, so we never publish 8 competing sessions.
@MainActor
final class NowPlayingController {
    static let shared = NowPlayingController()

    private var session: MPNowPlayingSession?
    /// Identity of the player that currently owns the session, so a stale `detach` from a view
    /// that already handed off to a newer player can't tear down the live one.
    private weak var currentPlayer: AVPlayer?

    private init() {}

    /// Publish `player` to the system playback UI with the given camera/clip metadata.
    /// Re-attaching the same player just refreshes its metadata.
    ///
    /// NOTE: the system only routes a Now Playing session to Control Center / Dynamic Island when
    /// the app holds an **active** `AVAudioSession`. Live tiles open muted and only activate
    /// `.playback` on unmute (a deliberate "don't duck the user's music for a silent video"
    /// policy), so in practice this surfaces once the camera is unmuted / for clips. Forcing the
    /// session active here would interrupt other audio for a muted feed — a UX regression — so we
    /// don't; if "show in Now Playing while muted" is wanted, that's an explicit policy change.
    func attach(player: AVPlayer, title: String, subtitle: String, isLive: Bool) {
        if currentPlayer === player, session != nil {
            publishMetadata(title: title, subtitle: subtitle, isLive: isLive)
            return
        }
        teardown()

        let session = MPNowPlayingSession(players: [player])
        session.automaticallyPublishesNowPlayingInfo = true
        self.session = session
        self.currentPlayer = player

        configureCommands(on: session, player: player, isLive: isLive)
        publishMetadata(title: title, subtitle: subtitle, isLive: isLive)
        session.becomeActiveIfPossible(completion: nil)
    }

    /// Stop publishing. If `player` is supplied, only detaches when it still owns the session —
    /// so a disappearing view can't yank a session a newer player already took over.
    func detach(player: AVPlayer?) {
        if let player, currentPlayer !== player { return }
        teardown()
    }

    private func teardown() {
        if let session, let player = currentPlayer {
            session.removePlayer(player)
        }
        session = nil
        currentPlayer = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func publishMetadata(title: String, subtitle: String, isLive: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: subtitle,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
        ]
        // AVPlayer has no inherent title; the session auto-publishes playback rate/position, but
        // we own the descriptive fields. Merge onto the session's center so both stay in sync.
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        session?.nowPlayingInfoCenter.nowPlayingInfo = info
    }

    private func configureCommands(on session: MPNowPlayingSession, player: AVPlayer, isLive: Bool) {
        let center = session.remoteCommandCenter

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        // Live has no timeline to scrub or skip through.
        center.changePlaybackPositionCommand.isEnabled = !isLive
        center.skipForwardCommand.isEnabled = !isLive
        center.skipBackwardCommand.isEnabled = !isLive

        center.playCommand.addTarget { [weak player] _ in
            player?.play(); return .success
        }
        center.pauseCommand.addTarget { [weak player] _ in
            player?.pause(); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak player] _ in
            guard let player else { return .commandFailed }
            if player.timeControlStatus == .paused { player.play() } else { player.pause() }
            return .success
        }
    }
}
