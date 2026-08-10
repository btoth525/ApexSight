import Foundation

/// Decides whether the shared Frigate session credential may ride along with a request.
///
/// The notification-service extension takes image URLs straight out of the push payload, and the
/// payload is only as trustworthy as whoever can reach the relay. Attaching the real Frigate JWT
/// to an arbitrary host would hand that host full camera/recording/config access, so the token is
/// only ever sent to the ONE origin the app itself signed in to (mirrored as
/// `apex.frigateBaseURL`).
///
/// **Fails closed on the credential, open on the alert.** When the origin can't be established the
/// answer is "don't attach" — the caller still performs the download, it just goes unauthenticated,
/// so the worst outcome is a notification without its picture, never a dropped notification.
public enum CredentialHostPolicy {

    /// Whether `url` is the same origin (scheme + host + effective port) as `frigateBaseURL`.
    public static func mayAttachCredentials(to url: URL, frigateBaseURL: String?) -> Bool {
        guard let raw = frigateBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let base = URL(string: raw),
              let baseHost = base.host?.lowercased(), !baseHost.isEmpty,
              let host = url.host?.lowercased(), !host.isEmpty,
              let baseScheme = base.scheme?.lowercased(),
              let scheme = url.scheme?.lowercased()
        else { return false }
        guard host == baseHost, scheme == baseScheme else { return false }
        return effectivePort(of: url) == effectivePort(of: base)
    }

    /// The port actually dialled: the explicit one, else the scheme default.
    private static func effectivePort(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}
