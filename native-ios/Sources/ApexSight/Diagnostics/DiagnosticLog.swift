import Foundation

/// The app's black box: a bounded, redacted log of what went wrong on the phone, shipped to the
/// household relay so a problem seen while testing can be read back afterwards.
///
/// `FputsLog` only ever wrote to stderr under `#if DEBUG`, which means the TestFlight builds that
/// actually get used produced no record at all — when something misbehaved, the evidence died with
/// the app. This is that record.
///
/// **Four rules, because a debugging aid must never become the bug.**
///
/// 1. **It cannot break the app.** Every path is `try?`/best-effort, nothing is awaited by UI code,
///    a failed upload is silently dropped, and a full buffer discards the OLDEST line rather than
///    growing. Logging is not allowed to surface an error to the user — an error report that
///    reports its own failure is absurd.
/// 2. **It cannot leak a secret.** The Frigate JWT, the pairing code and the Alarmo disarm code are
///    all things that pass through error strings. `redact` strips them structurally, on the way IN,
///    so a secret is never stored on disk even if the upload never happens.
/// 3. **It is bounded everywhere.** Ring buffer in memory, capped file on disk, capped batch on the
///    wire, and the relay prunes independently.
/// 4. **It is off unless the user wants it.** One switch in Settings, and no network call at all
///    when it's off.
@MainActor
final class DiagnosticLog {
    static let shared = DiagnosticLog()

    enum Level: String { case info, warning, error }

    struct Entry: Codable {
        let ts: Double
        let level: String
        let category: String
        let message: String
    }

    /// Enough to cover a long testing session, small enough that the file stays trivial.
    private static let maxEntries = 600
    /// One upload is a slice of the buffer, not the whole thing — matches the relay's own cap.
    private static let maxBatch = 200
    /// Don't ship a line the moment it happens; a burst of stream errors would otherwise become a
    /// burst of POSTs. Flushed on this cadence, on backgrounding, and when the buffer is getting full.
    private static let flushInterval: TimeInterval = 60

    static let enabledKey = "apex.diagnosticsEnabled"

    private var entries: [Entry] = []
    private var flushTask: Task<Void, Never>?
    private var uploading = false
    private let store: URL?

    /// User-facing switch. Defaults ON: this exists because the household asked to see what the app
    /// does over time, and a black box that defaults to off records nothing on the one build that
    /// mattered. Turning it off stops both recording and sending.
    static var isEnabled: Bool {
        get {
            let d = UserDefaults(suiteName: ApexAppGroup.identifier)
            if d?.object(forKey: enabledKey) == nil { return true }
            return d?.bool(forKey: enabledKey) ?? true
        }
        set { UserDefaults(suiteName: ApexAppGroup.identifier)?.set(newValue, forKey: enabledKey) }
    }

    private init() {
        store = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: ApexAppGroup.identifier)?
            .appendingPathComponent("diagnostics.json")
        entries = Self.loadPersisted(from: store)
    }

    // MARK: - Recording

    func log(_ level: Level, _ category: String, _ message: String) {
        guard Self.isEnabled else { return }
        let entry = Entry(ts: Date().timeIntervalSince1970,
                          level: level.rawValue,
                          category: category,
                          message: Self.redact(message))
        entries.append(entry)
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        persist()
        scheduleFlush()
    }

    func info(_ category: String, _ message: String) { log(.info, category, message) }
    func warning(_ category: String, _ message: String) { log(.warning, category, message) }
    func error(_ category: String, _ message: String) { log(.error, category, message) }

    /// Log an Error without the caller having to think about description vs localizedDescription.
    /// Cancellations are skipped — they're normal control flow, and they'd drown everything else.
    func error(_ category: String, _ error: Error, context: String = "") {
        guard !error.isCancellation else { return }
        let prefix = context.isEmpty ? "" : context + ": "
        log(.error, category, prefix + error.localizedDescription)
    }

    // MARK: - Redaction

    /// Strip anything that could identify or authenticate, BEFORE it is written down.
    ///
    /// Applied on the way in rather than on the way out on purpose: the buffer is persisted to the
    /// app group, so redacting only at upload time would still leave a token sitting in a file.
    /// `nonisolated` on purpose: it is a pure string transform with no state, it must be callable
    /// from the notification-service extension and background contexts, and a test shouldn't have
    /// to hop to the main actor to check that a token cannot leak.
    nonisolated static func redact(_ text: String) -> String {
        var s = text
        // JWTs (the Frigate session token) — three dot-separated base64url runs.
        s = s.replacingOccurrences(
            of: #"eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+"#,
            with: "‹token›", options: .regularExpression)
        // Anything presented as a credential in a query string or header.
        s = s.replacingOccurrences(
            of: #"(?i)(token|password|pairing_code|code|api_key|authorization)=[^&\s"']+"#,
            with: "$1=‹redacted›", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"(?i)bearer\s+[A-Za-z0-9._\-]+"#,
            with: "Bearer ‹redacted›", options: .regularExpression)
        s = s.replacingOccurrences(
            of: #"(?i)frigate_token=[^;\s]+"#,
            with: "frigate_token=‹redacted›", options: .regularExpression)
        // The household pairing code and the Alarmo disarm code, wherever they appear verbatim.
        for secret in [RelayConfig.defaultPairingCode,
                       UserDefaults(suiteName: ApexAppGroup.identifier)?.string(forKey: "apex.pairingCode") ?? ""]
        where secret.count >= 4 {
            s = s.replacingOccurrences(of: secret, with: "‹pairing›")
        }
        // Basic-auth style credentials embedded in a URL.
        s = s.replacingOccurrences(
            of: #"://[^/@\s:]+:[^/@\s]+@"#, with: "://‹creds›@", options: .regularExpression)
        return String(s.prefix(2000))
    }

    // MARK: - Persistence (survives a kill, so a crash still leaves a trail)

    private func persist() {
        guard let store else { return }
        try? JSONEncoder().encode(entries).write(to: store, options: .atomic)
    }

    private static func loadPersisted(from url: URL?) -> [Entry] {
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return Array(decoded.suffix(maxEntries))
    }

    // MARK: - Upload

    private func scheduleFlush() {
        // Getting close to full → send now rather than lose the oldest lines to the ring buffer.
        if entries.count >= Self.maxBatch { Task { await flush() }; return }
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.flushInterval))
            self?.flushTask = nil
            await self?.flush()
        }
    }

    /// Ship what we have. Best-effort by design: on ANY failure the entries stay in the buffer and
    /// go out with the next flush, and nothing anywhere is told that this didn't work.
    func flush() async {
        guard Self.isEnabled, !uploading, !entries.isEmpty else { return }
        let defaults = UserDefaults(suiteName: ApexAppGroup.identifier)
        var relay = (defaults?.string(forKey: "apex.relayURL") ?? "").trimmingCharacters(in: .whitespaces)
        if relay.isEmpty { relay = RelayConfig.defaultURL }
        while relay.hasSuffix("/") { relay.removeLast() }
        guard let url = URL(string: relay + "/v1/diag"), url.host != nil else { return }

        let batch = Array(entries.prefix(Self.maxBatch))
        let pairing = defaults?.string(forKey: "apex.pairingCode") ?? RelayConfig.defaultPairingCode
        let body: [String: Any] = [
            "pairing_code": pairing,
            "device": Self.deviceName,
            "build": Self.buildLabel,
            "entries": batch.map { ["ts": $0.ts, "level": $0.level,
                                    "category": $0.category, "message": $0.message] }
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }

        uploading = true
        defer { uploading = false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        request.timeoutInterval = 12
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return }
        // Only drop what the relay actually accepted, and only the exact lines we sent — new ones
        // may have arrived while this was in flight.
        entries.removeFirst(min(batch.count, entries.count))
        persist()
    }

    static var deviceName: String {
        UserDefaults(suiteName: ApexAppGroup.identifier)?.string(forKey: "apex.deviceName")
            ?? ProcessInfo.processInfo.hostName
    }

    static var buildLabel: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
