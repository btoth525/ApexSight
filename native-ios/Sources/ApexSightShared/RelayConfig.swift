import Foundation

/// Where the ApexSight push relay lives.
///
/// `defaultURL` is the relay every copy of the app talks to by default. It is
/// NOT a secret (it's just your public Cloudflare Tunnel hostname), so it's safe
/// to bake in. Set it to your relay before shipping a TestFlight/App Store build
/// so testers are paired automatically with zero configuration. Users can still
/// override it in Settings → Instant Push.
enum RelayConfig {
    /// The relay every copy of the app talks to. Baked in so testers need zero setup.
    static let defaultURL = "https://relay.plexserver525.com"

    /// Baked household pairing code for this PRIVATE single-household build (Brandon + wife).
    /// MUST match the HA add-on's `pairing_code` (apexsight-push config.yaml → "APEX-PLEX-5250")
    /// or the relay routes the add-on's pushes to a device set this phone isn't in.
    ///
    /// Why this is set (was ""): a reinstall wipes the app-group container, so the previously
    /// stored code is lost; with an empty default `ensurePairingCode()` would mint a NEW random
    /// code and the phone would silently stop receiving the add-on's pushes (which always target
    /// the fixed household code). Baking the shared code makes every install/reinstall auto-rejoin
    /// the household with zero setup. (Leave "" only for a public multi-household/account build.)
    static let defaultPairingCode = "APEX-PLEX-5250"
}
