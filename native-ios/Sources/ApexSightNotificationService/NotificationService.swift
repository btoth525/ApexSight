import Foundation
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

        guard let attachmentURL = attachmentURL(from: request.content.userInfo) else {
            contentHandler(mutableContent)
            return
        }

        var urlRequest = URLRequest(url: attachmentURL)
        if let token = request.content.userInfo["frigate_token"] as? String, !token.isEmpty {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue("frigate_token=\(token)", forHTTPHeaderField: "Cookie")
        }

        downloadTask = URLSession.shared.downloadTask(with: urlRequest) { [weak self] temporaryURL, _, _ in
            guard
                let self,
                let temporaryURL,
                let attachment = self.copyAttachment(from: temporaryURL, originalURL: attachmentURL)
            else {
                contentHandler(mutableContent)
                return
            }

            mutableContent.attachments = [attachment]
            contentHandler(mutableContent)
        }
        downloadTask?.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        downloadTask?.cancel()
        if let bestAttemptContent {
            contentHandler?(bestAttemptContent)
        }
    }

    private func attachmentURL(from userInfo: [AnyHashable: Any]) -> URL? {
        let candidates = ["snapshot_url", "image_url", "thumbnail_url"]
        for key in candidates {
            if let value = userInfo[key] as? String, let url = URL(string: value) {
                return url
            }
        }
        return nil
    }

    private func copyAttachment(from temporaryURL: URL, originalURL: URL) -> UNNotificationAttachment? {
        let fileExtension = originalURL.pathExtension.isEmpty ? "jpg" : originalURL.pathExtension
        let localURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("apex-alert-\(UUID().uuidString).\(fileExtension)")

        do {
            try FileManager.default.copyItem(at: temporaryURL, to: localURL)
            return try UNNotificationAttachment(identifier: "frigate-snapshot", url: localURL)
        } catch {
            return nil
        }
    }
}
