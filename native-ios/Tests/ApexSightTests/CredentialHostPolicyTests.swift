import Foundation
import Testing
@testable import ApexSightNative

/// The notification-service extension downloads alert images from URLs it reads out of the push
/// payload, and it used to attach the real Frigate JWT to whatever host those URLs named. Anyone
/// who could POST to the relay could therefore have both household phones hand over a token that
/// grants full camera, recording and config access.
///
/// Two directions matter and they pull opposite ways:
///  • the credential must fail CLOSED — anything that isn't provably the signed-in origin gets no
///    token, including "can't tell";
///  • the alert must fail OPEN — the caller still downloads without credentials, so the worst
///    outcome of a false negative here is a picture-less notification, never a dropped one.
@Suite("CredentialHostPolicy")
struct CredentialHostPolicyTests {
    private let base = "https://frigate.example.com"

    private func may(_ url: String, base: String?) -> Bool {
        guard let u = URL(string: url) else { return false }
        return CredentialHostPolicy.mayAttachCredentials(to: u, frigateBaseURL: base)
    }

    // MARK: - The legitimate path keeps its token

    @Test("The relay's own snapshot URL still gets the token")
    func sameOriginAllowed() {
        #expect(may("\(base)/api/events/1.2-abc/snapshot.jpg?bbox=1&crop=1", base: base))
    }

    @Test("A base URL with a trailing slash, path, or stray whitespace still matches")
    func baseNormalisation() {
        #expect(may("\(base)/api/x.jpg", base: "\(base)/"))
        #expect(may("\(base)/api/x.jpg", base: "  \(base)  "))
        #expect(may("\(base)/api/x.jpg", base: "\(base)/api"))
    }

    @Test("Host comparison ignores case, as DNS does")
    func hostCaseInsensitive() {
        #expect(may("https://FRIGATE.example.COM/api/x.jpg", base: base))
    }

    @Test("An explicit LAN host with a port matches itself")
    func explicitPortMatches() {
        #expect(may("http://192.168.1.204:5000/api/x.jpg", base: "http://192.168.1.204:5000"))
    }

    @Test("A default port written out explicitly is still the same origin")
    func defaultPortIsEquivalent() {
        #expect(may("https://frigate.example.com:443/api/x.jpg", base: base))
        #expect(may("http://frigate.example.com/api/x.jpg", base: "http://frigate.example.com:80"))
    }

    // MARK: - Everything else is denied

    @Test("A foreign host named by the payload gets no token — the actual exfiltration path")
    func foreignHostDenied() {
        #expect(!may("https://attacker.example/x.jpg", base: base))
    }

    @Test("A subdomain of the real host is still a different host")
    func subdomainDenied() {
        #expect(!may("https://frigate.example.com.attacker.example/x.jpg", base: base))
        #expect(!may("https://evil.frigate.example.com/x.jpg", base: base))
    }

    @Test("Downgrading the scheme would put the token on the wire in clear — denied")
    func schemeMismatchDenied() {
        #expect(!may("http://frigate.example.com/api/x.jpg", base: base))
    }

    @Test("A different port on the right host is a different service — denied")
    func portMismatchDenied() {
        #expect(!may("https://frigate.example.com:8443/api/x.jpg", base: base))
        #expect(!may("http://192.168.1.204:5001/api/x.jpg", base: "http://192.168.1.204:5000"))
    }

    @Test("Unknown origin fails closed rather than guessing")
    func unknownBaseDenied() {
        #expect(!may("\(base)/api/x.jpg", base: nil))
        #expect(!may("\(base)/api/x.jpg", base: ""))
        #expect(!may("\(base)/api/x.jpg", base: "   "))
        #expect(!may("\(base)/api/x.jpg", base: "not a url at all"))
    }

    @Test("A hostless URL — file:, data:, a bare path — never carries the token")
    func hostlessDenied() {
        #expect(!may("file:///etc/passwd", base: base))
        #expect(!may("data:image/gif;base64,AAAA", base: base))
        #expect(!may("/api/events/x/snapshot.jpg", base: base))
    }
}
