import Foundation
import UniformTypeIdentifiers
import UserNotifications
import WidgetKit

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var downloadTask: URLSessionDownloadTask?
    private var widgetRefresh: Task<Void, Never>?
    private let deliveryLock = NSLock()
    private var hasDelivered = false

    /// Deliver the notification to the system exactly once. The download completion, the bounded
    /// widget-wait, and `serviceExtensionTimeWillExpire` can all race to deliver; iOS ignores a
    /// second call, but the once-guard keeps the contract clean and drops the handler + best-attempt
    /// so nothing is retained past delivery.
    private func deliverOnce(_ content: UNNotificationContent) {
        deliveryLock.lock()
        let firstTime = !hasDelivered
        hasDelivered = true
        let handler = contentHandler
        contentHandler = nil
        deliveryLock.unlock()
        if firstTime { handler?(content) }
    }

    /// Await the widget refresh, but at most `seconds` — never hold the user-facing alert hostage to
    /// a slow or unreachable Frigate (WidgetKit re-refreshes on its own timeline regardless).
    private static func awaitBounded(_ task: Task<Void, Never>?, seconds: Double) async {
        guard let task else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
    }

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler

        guard let mutableContent = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }

        bestAttemptContent = mutableContent

        // Keep the app-icon badge + Home/Lock-Screen widgets fresh while the app is
        // closed — the NSE runs on every push, so this is what makes them update
        // without opening the app.
        Self.bumpBadgeAndRefreshWidgets(for: request.content, into: mutableContent)

        // Refresh the widgets with the CURRENT Frigate state (same data the app shows): fetch
        // the latest un-reviewed alerts + hero thumbnail and rewrite the widget cache, then
        // reload ONCE. Runs alongside the attachment download, but delivery WAITS for it —
        // iOS suspends the extension the moment contentHandler runs, which was silently
        // dropping in-flight refreshes. Both fit comfortably in the ~30s NSE budget.
        widgetRefresh = Task {
            await WidgetDataFetcher.refresh()
            WidgetCenter.shared.reloadAllTimelines()
        }

        // Prefer a token sent in the payload; otherwise fall back to the one the
        // app mirrors into the shared app group (remote pushes from the HA bridge
        // carry no user token, so this is how authenticated Frigate snapshots load).
        let payloadToken = request.content.userInfo["frigate_token"] as? String
        let token = (payloadToken?.isEmpty == false) ? payloadToken : Self.appGroupToken()
        let candidates = attachmentURLs(from: request.content.userInfo)
        guard !candidates.isEmpty else {
            Task {
                await Self.awaitBounded(self.widgetRefresh, seconds: 3)
                self.deliverOnce(mutableContent)
            }
            return
        }

        // Try the animated GIF first, then static fallbacks, until one downloads.
        // No on-device AI text is added — the user wants the alert exactly as sent,
        // with the picture attached (the "👁️ …" Vision subtitle was removed by request).
        download(candidates, token: token) { [weak self] attachment in
            guard let self else { return }
            if let attachment {
                mutableContent.attachments = [attachment]
            }
            Task {
                await Self.awaitBounded(self.widgetRefresh, seconds: 3)
                self.deliverOnce(mutableContent)
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        downloadTask?.cancel()
        widgetRefresh?.cancel()
        if let bestAttemptContent {
            deliverOnce(bestAttemptContent)
        }
    }

    /// Ordered list of media URLs to try: animated GIF (snapshot_url) first, then stills.
    /// Absolute `*_url` keys are used as-is; a relative `snapshot_path` (e.g.
    /// "/api/events/<id>/preview.gif") is resolved against the app-group base URL.
    ///
    /// Correctness guard: Frigate builds `preview.gif` from preview frames, and for an event
    /// only a few seconds old those frames can PREDATE the event — the notification would show
    /// the wrong footage. The event's start time is embedded in its id (epoch prefix, part of
    /// the URL), so when the event is younger than ~15s we demote GIFs behind the stills —
    /// the still is always current, and the silent "final GIF" follow-up push carries the
    /// correct animated preview once the event has actually run.
    private func attachmentURLs(from userInfo: [AnyHashable: Any]) -> [URL] {
        var urls: [URL] = []
        for key in ["snapshot_url", "thumbnail_url", "image_url"] {
            if let value = userInfo[key] as? String, let url = URL(string: value) {
                urls.append(url)
            }
        }
        if let path = userInfo["snapshot_path"] as? String,
           let base = Self.appGroupBaseURL(),
           let url = URL(string: base.hasSuffix("/") || path.hasPrefix("/") ? base + path : base + "/" + path) {
            urls.append(url)
        }
        if let eventStart = urls.lazy.compactMap(Self.eventStartTime(fromURL:)).first,
           Date().timeIntervalSince1970 - eventStart < 15 {
            let (gifs, stills) = urls.reduce(into: ([URL](), [URL]())) { acc, url in
                if url.path.lowercased().hasSuffix(".gif") { acc.0.append(url) } else { acc.1.append(url) }
            }
            return stills + gifs
        }
        return urls
    }

    /// Frigate event ids look like `1783198550.714144-fzdnog` — the prefix is the event's epoch
    /// start. Parse it out of an `/api/events/<id>/…` URL; nil when the URL isn't event-shaped.
    private static func eventStartTime(fromURL url: URL) -> Double? {
        let parts = url.pathComponents
        guard let idx = parts.firstIndex(of: "events"), parts.count > idx + 1 else { return nil }
        let id = parts[idx + 1]
        guard let dash = id.firstIndex(of: "-"), let start = Double(id[..<dash]), start > 1_000_000_000 else { return nil }
        return start
    }

    /// Increment the shared badge counter (so the app icon updates on a closed-app push,
    /// like Mail) and nudge the widgets to refetch. The silent "final GIF" follow-up is
    /// passive, so it refreshes widgets without double-counting the badge.
    private static func bumpBadgeAndRefreshWidgets(for content: UNNotificationContent, into mutable: UNMutableNotificationContent) {
        let defaults = UserDefaults(suiteName: appGroupSuite)
        let info = content.userInfo
        let hasReviewID = (info["review_id"] as? String).map { !$0.isEmpty } ?? false
        let noBadge = (info["no_badge"] as? Bool) == true || (info["no_badge"] as? NSNumber)?.boolValue == true
        // Bump only for a real, first-time event alert: it must carry a review_id (excludes the
        // Daily Recap summary and the diagnostic test push) and must not be flagged no_badge
        // (excludes the silent final-GIF and announce-only AI-description follow-ups, which REPLACE
        // an existing alert in place via the shared collapse-id — counting them double-badges).
        if hasReviewID, !noBadge, content.interruptionLevel != .passive {
            let next = (defaults?.integer(forKey: "apex.badgeCount") ?? 0) + 1
            defaults?.set(next, forKey: "apex.badgeCount")
            mutable.badge = NSNumber(value: next)
            // Mark real alerts Time Sensitive so they break through a Driving / Do Not Disturb
            // Focus and surface on CarPlay (requires the time-sensitive entitlement on the app).
            mutable.interruptionLevel = .timeSensitive
        }
        // (Widget reload happens once in didReceive, after the fresh data is written —
        // reloading here too was a second full timeline rebuild per push.)
    }

    // MARK: - App-group fallbacks (written by the main app on login/refresh)

    private static let appGroupSuite = "group.com.brandontoth.apexsight"

    private static func appGroupToken() -> String? {
        // Token now lives in the shared Keychain access group (no longer plaintext in the
        // App-Group plist). A miss falls through to the no-token path, which downloads the
        // unauthenticated snapshot or the bundled placeholder — never a crash.
        SharedTokenStore.load()
    }

    private static func appGroupBaseURL() -> String? {
        UserDefaults(suiteName: appGroupSuite)?.string(forKey: "apex.frigateBaseURL")
    }

    private func download(_ urls: [URL], token: String?, completion: @escaping (UNNotificationAttachment?) -> Void) {
        guard let url = urls.first else {
            completion(nil)
            return
        }
        let remaining = Array(urls.dropFirst())

        var urlRequest = URLRequest(url: url)
        // The extension has a hard ~30s budget before iOS kills it and delivers the
        // notification without media. Cap each attempt so a slow/unreachable Frigate
        // fails fast and we can still try the next candidate (or give up cleanly)
        // well inside that window.
        urlRequest.timeoutInterval = 8
        // The candidate URLs come out of the push payload, so the host is remote-controlled.
        // Only ever hand the Frigate session token to the origin the app itself signed in to —
        // otherwise a forged payload would exfiltrate a JWT that grants full camera access.
        // An off-origin candidate still downloads, just unauthenticated: worst case a missing
        // picture, never a missing alert.
        if let token, !token.isEmpty,
           CredentialHostPolicy.mayAttachCredentials(to: url, frigateBaseURL: Self.appGroupBaseURL()) {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue("frigate_token=\(token)", forHTTPHeaderField: "Cookie")
        }

        downloadTask = URLSession.shared.downloadTask(with: urlRequest) { [weak self] temporaryURL, response, _ in
            guard let self else { return }
            // Require a genuine 2xx. `?? false` so a non-HTTP response — or a reverse
            // proxy that answers auth failures with a 200 + HTML login page — is
            // rejected and we try the next candidate instead of attaching garbage.
            if let temporaryURL,
               (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
               let attachment = self.copyAttachment(from: temporaryURL, originalURL: url) {
                completion(attachment)
            } else {
                // Fall back to the next candidate (e.g. GIF not ready → static thumbnail).
                self.download(remaining, token: token, completion: completion)
            }
        }
        downloadTask?.resume()
    }

    private func copyAttachment(from temporaryURL: URL, originalURL: URL) -> UNNotificationAttachment? {
        let fileExtension = originalURL.pathExtension.isEmpty ? "jpg" : originalURL.pathExtension.lowercased()
        let localURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("apex-alert-\(UUID().uuidString).\(fileExtension)")

        do {
            try FileManager.default.copyItem(at: temporaryURL, to: localURL)
            // A type hint makes the system animate GIFs reliably in the expanded view.
            var options: [String: Any]? = nil
            if fileExtension == "gif" {
                options = [UNNotificationAttachmentOptionsTypeHintKey: UTType.gif.identifier]
            }
            return try UNNotificationAttachment(identifier: "frigate-media", url: localURL, options: options)
        } catch {
            return nil
        }
    }
}
