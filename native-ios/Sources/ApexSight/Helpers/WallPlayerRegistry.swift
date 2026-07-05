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
        guard let player = players[camera] else { return nil }
        borrowed.insert(camera)
        return player
    }

    func endBorrow(_ camera: String) { borrowed.remove(camera) }
    func isBorrowed(_ camera: String) -> Bool { borrowed.contains(camera) }
}
