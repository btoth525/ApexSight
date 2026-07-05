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

    func register(_ player: AVPlayer, for camera: String) {
        guard !camera.isEmpty else { return }
        players[camera] = player
    }

    /// Only removes the entry if it still points at THIS player (a newer registration wins).
    func unregister(_ player: AVPlayer, for camera: String) {
        if players[camera] === player { players[camera] = nil }
    }

    func player(for camera: String) -> AVPlayer? { players[camera] }
}
