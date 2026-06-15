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

        let token = request.content.userInfo["frigate_token"] as? String
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
    private func attachmentURLs(from userInfo: [AnyHashable: Any]) -> [URL] {
        let keys = ["snapshot_url", "thumbnail_url", "image_url"]
        var urls: [URL] = []
        for key in keys {
            if let value = userInfo[key] as? String, let url = URL(string: value) {
                urls.append(url)
            }
        }
        return urls
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
