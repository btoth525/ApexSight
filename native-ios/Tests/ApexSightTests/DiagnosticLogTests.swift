import Foundation
import Testing
@testable import ApexSightNative

/// The diagnostic log ships the app's errors to the household relay. It is a debugging aid bolted
/// onto a security app, which makes it exactly the kind of feature that quietly becomes the
/// vulnerability — so the thing under test here is not "does it log", it's "can it leak".
///
/// Redaction runs on the way IN, before anything touches disk, because the buffer is persisted to
/// the app group: scrubbing only at upload time would still leave a live Frigate token sitting in
/// a file on the device.
@Suite("Diagnostic log redaction")
struct DiagnosticLogTests {

    @Test("A Frigate JWT never survives into the log")
    func stripsJWT() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJicmFuZG9uIiwiZXhwIjo5OTk5fQ.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let out = DiagnosticLog.redact("request failed with Authorization: Bearer \(jwt)")
        #expect(!out.contains(jwt))
        #expect(!out.contains("eyJ"), "not even the header fragment")
    }

    @Test("Credentials in a query string are replaced, and the key is kept for context")
    func stripsQueryCredentials() {
        let out = DiagnosticLog.redact(
            "GET /api/review?pairing_code=APEX-PLEX-5250&token=abc123def&limit=10 failed")
        #expect(!out.contains("APEX-PLEX-5250"))
        #expect(!out.contains("abc123def"))
        #expect(out.contains("limit=10"), "non-secret params stay — they're the useful part")
        #expect(out.contains("pairing_code="), "the KEY stays so the line is still readable")
    }

    @Test("A cookie-borne token is stripped")
    func stripsCookieToken() {
        let out = DiagnosticLog.redact("Cookie: frigate_token=eyJhb.superSecretValue; other=1")
        #expect(!out.contains("superSecretValue"))
    }

    @Test("Credentials embedded in a URL are stripped")
    func stripsURLCredentials() {
        let out = DiagnosticLog.redact("failed to open rtsp://admin:hunter2@192.168.1.136:554/stream")
        #expect(!out.contains("hunter2"))
        #expect(out.contains("192.168.1.136"), "the host is diagnostic signal, not a secret")
    }

    /// The household pairing code is the credential that gates arming, disarming and ringing every
    /// phone. It must never be written down verbatim, wherever in the string it appears.
    @Test("The household pairing code is scrubbed even in free text")
    func stripsPairingCodeAnywhere() {
        let out = DiagnosticLog.redact(
            "set-mode rejected for \(RelayConfig.defaultPairingCode) — relay said 403")
        #expect(!out.contains(RelayConfig.defaultPairingCode))
        #expect(out.contains("403"), "the actual diagnostic survives")
    }

    @Test("An ordinary error message is left completely alone")
    func keepsOrdinaryText() {
        let msg = "The request timed out after 15 seconds while loading Front_Driveway"
        #expect(DiagnosticLog.redact(msg) == msg)
    }

    /// A runaway error loop must not be able to post a megabyte of text to the relay.
    @Test("A single entry is length-bounded")
    func boundsLength() {
        let huge = String(repeating: "x", count: 50_000)
        #expect(DiagnosticLog.redact(huge).count <= 2000)
    }

    @Test("Redaction is idempotent — re-logging an already-scrubbed line changes nothing")
    func idempotent() {
        let once = DiagnosticLog.redact("Bearer abc.def.ghi and token=zzz")
        #expect(DiagnosticLog.redact(once) == once)
    }

    /// Cancellations are normal control flow — every backgrounded fetch produces one. Recording
    /// them would bury the real errors, which is the same "badge everything and it means nothing"
    /// failure the threat ratings had.
    @Test("Cancellations are not recorded as errors")
    func skipsCancellations() {
        #expect(CancellationError().isCancellation)
        let urlCancel = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        #expect(urlCancel.isCancellation)
    }
}
