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

    /// Empty on purpose for the public, account-based build: push routing now comes
    /// from the signed-in account's private ingest token (set via AccountStore), so
    /// each user only ever receives their own alerts. (Set a value here only for a
    /// private single-household build where every install should auto-join one code.)
    static let defaultPairingCode = ""
}
