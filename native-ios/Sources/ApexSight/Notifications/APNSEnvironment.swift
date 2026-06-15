import Foundation

/// Detects whether this build talks to the APNs **production** or **sandbox**
/// servers, so the relay can route pushes to the matching endpoint.
///
/// We read the actual `aps-environment` from the embedded provisioning profile
/// rather than guessing from `#if DEBUG` — that's the value Apple uses to decide
/// which APNs environment your device token belongs to. App Store / TestFlight
/// builds have no embedded profile → production.
enum APNSEnvironment {
    static var current: String {
        guard
            let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .isoLatin1)
        else {
            return "production"
        }
        // The profile is a CMS blob with an embedded XML plist; scan it for the
        // aps-environment value. "development" → sandbox, anything else → prod.
        guard let range = text.range(of: "aps-environment") else { return "production" }
        let tail = text[range.upperBound...].prefix(120)
        return tail.contains("development") ? "sandbox" : "production"
    }
}
