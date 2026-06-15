import Foundation
import UniformTypeIdentifiers
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var downloadTask: URLSessionDownloadTask?

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

        // Prefer a token sent in the payload; otherwise fall back to the one the
        // app mirrors into the shared app group (remote pushes from the HA bridge
        // carry no user token, so this is how authenticated Frigate snapshots load).
        let payloadToken = request.content.userInfo["frigate_token"] as? String
        let token = (payloadToken?.isEmpty == false) ? payloadToken : Self.appGroupToken()
        let candidates = attachmentURLs(from: request.content.userInfo)
        guard !candidates.isEmpty else {
            contentHandler(mutableContent)
            return
        }

        // Try the animated GIF first, then static fallbacks, until one downloads.
        download(candidates, token: token) { [weak self] attachment in
            guard let self else { return }
            if let attachment {
                mutableContent.attachments = [attachment]
            }
            self.contentHandler?(mutableContent)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        downloadTask?.cancel()
        if let bestAttemptContent {
            contentHandler?(bestAttemptContent)
        }
    }

    /// Ordered list of media URLs to try: animated GIF (snapshot_url) first, then stills.
    /// Absolute `*_url` keys are used as-is; a relative `snapshot_path` (e.g.
    /// "/api/events/<id>/preview.gif") is resolved against the app-group base URL.
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
        return urls
    }

    // MARK: - App-group fallbacks (written by the main app on login/refresh)

    private static let appGroupSuite = "group.com.brandontoth.apexsight"

    private static func appGroupToken() -> String? {
        UserDefaults(suiteName: appGroupSuite)?.string(forKey: "apex.frigateToken")
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
        if let token, !token.isEmpty {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue("frigate_token=\(token)", forHTTPHeaderField: "Cookie")
        }

        downloadTask = URLSession.shared.downloadTask(with: urlRequest) { [weak self] temporaryURL, response, _ in
            guard let self else { return }
            if let temporaryURL,
               (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
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
