import AVFoundation

/// The wall tiles' live AVPlayers, by camera — so the full-screen viewer can show the tile's
/// ALREADY-DECODING stream the instant it opens (zero black, zero connect) while its own
/// full-quality player spins up behind it. Tiles register when they reach `.playing` and
/// unregister on stop; entries are bounded by the camera count and overwritten on re-register,
/// so a stale entry can never outlive a server switch.
@MainActor
final class WallPlayerRegistry {
    static let shared = WallPlayerRegistry()
    private var players: [String: AVPlayer] = [:]
    /// Cameras whose player the full-screen viewer is currently SHOWING. The wall tile's
    /// onDisappear fires right after the viewer's onAppear during the push — without this flag
    /// its pause would freeze the very player the viewer just resumed (handoff showed a still
    /// frame instead of moving video).
    private var borrowed: Set<String> = []
    /// Cameras whose tile went OFF-SCREEN while its player was borrowed. The tile skipped its own
    /// pause so the handoff kept moving; whoever ends the borrow owes that pause — otherwise the
    /// wall's sub stream kept decoding underneath the full-screen viewer for the whole session.
    private var pauseDeferred: Set<String> = []

    func register(_ player: AVPlayer, for camera: String) {
        guard !camera.isEmpty else { return }
        players[camera] = player
    }

    /// Only removes the entry if it still points at THIS player (a newer registration wins).
    func unregister(_ player: AVPlayer, for camera: String) {
        if players[camera] === player { players[camera] = nil }
    }

    /// The full-screen viewer takes the warm player and marks it borrowed so the tile's
    /// pause-on-disappear leaves it running. Balanced by `endBorrow`.
    func borrow(_ camera: String) -> AVPlayer? {
        // A PAUSED registration is a tile that scrolled away minutes ago: handing it over shows a
        // stale frame that immediately stalls, and the stall reconnects the OFF-SCREEN tile.
        guard let player = players[camera], player.timeControlStatus != .paused else { return nil }
        borrowed.insert(camera)
        return player
    }

    /// The tile disappeared mid-borrow and left its player running for the handoff.
    func deferPause(_ camera: String) { pauseDeferred.insert(camera) }

    /// Returns true when the tile went off-screen during the borrow — the caller must pause the
    /// player it is handing back, because nothing else will.
    @discardableResult
    func endBorrow(_ camera: String) -> Bool {
        borrowed.remove(camera)
        return pauseDeferred.remove(camera) != nil
    }

    /// Server switch / sign-out: nothing here belongs to the next session. Pause first so a player
    /// that only the registry still references stops pulling the OLD server's stream.
    func removeAll() {
        players.values.forEach { $0.pause() }
        players.removeAll()
        borrowed.removeAll()
        pauseDeferred.removeAll()
    }
    func isBorrowed(_ camera: String) -> Bool { borrowed.contains(camera) }
}
