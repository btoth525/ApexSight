import UserNotifications

/// Notification Service Extension for Apex Sight.
///
/// iOS delivers push notifications to this extension BEFORE displaying them,
/// giving us a chance to download and attach the snapshot image so it shows
/// on the lock screen even when the main app is fully killed.
///
/// Works with Expo Push payload formats:
///   1. body.attachments[0].url             (our preferred format)
///   2. body.richContent.image              (Expo's standard rich content)
///   3. attachments[0].url                  (top-level fallback)
///   4. data.image / data.imageUrl          (custom data field)
class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttempt = request.content.mutableCopy() as? UNMutableNotificationContent

        guard let bestAttempt = bestAttempt else {
            contentHandler(request.content)
            return
        }

        guard let imageUrlString = extractImageUrl(from: bestAttempt.userInfo),
              let imageUrl = URL(string: imageUrlString) else {
            contentHandler(bestAttempt)
            return
        }

        downloadAndAttach(url: imageUrl, content: bestAttempt) { finalContent in
            contentHandler(finalContent)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // iOS gives us ~30s. If we run out, deliver the text-only version.
        if let handler = contentHandler, let content = bestAttempt {
            handler(content)
        }
    }

    // MARK: - Image URL extraction

    private func extractImageUrl(from userInfo: [AnyHashable: Any]) -> String? {
        // Expo Push wraps app data under "body"
        if let body = userInfo["body"] as? [String: Any] {
            if let attachments = body["attachments"] as? [[String: Any]],
               let url = attachments.first?["url"] as? String {
                return url
            }
            if let richContent = body["richContent"] as? [String: Any] {
                if let image = richContent["image"] as? String { return image }
            }
            if let data = body["data"] as? [String: Any] {
                if let image = data["image"] as? String { return image }
                if let image = data["imageUrl"] as? String { return image }
            }
        }
        // Top-level fallbacks
        if let attachments = userInfo["attachments"] as? [[String: Any]],
           let url = attachments.first?["url"] as? String {
            return url
        }
        if let richContent = userInfo["richContent"] as? [String: Any],
           let image = richContent["image"] as? String {
            return image
        }
        return nil
    }

    // MARK: - Download

    private func downloadAndAttach(
        url: URL,
        content: UNMutableNotificationContent,
        completion: @escaping (UNNotificationContent) -> Void
    ) {
        let task = URLSession.shared.downloadTask(with: url) { localUrl, response, error in
            defer {
                // No matter what, deliver the notification — with image if possible
                completion(content)
            }

            guard error == nil, let localUrl = localUrl else { return }

            // iOS reads attachments from a stable location, so move the file
            let tmp = FileManager.default.temporaryDirectory
            let ext = self.fileExtension(for: url, response: response)
            let dest = tmp.appendingPathComponent("\(UUID().uuidString).\(ext)")

            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: localUrl, to: dest)
                let attachment = try UNNotificationAttachment(
                    identifier: "image",
                    url: dest,
                    options: nil
                )
                content.attachments = [attachment]
            } catch {
                // Swallow — already deferring fallback delivery
            }
        }
        task.resume()
    }

    private func fileExtension(for url: URL, response: URLResponse?) -> String {
        let mime = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if mime.contains("png") { return "png" }
        if mime.contains("webp") { return "webp" }
        if mime.contains("gif") { return "gif" }
        let pathExt = url.pathExtension.lowercased()
        if !pathExt.isEmpty { return pathExt }
        return "jpg"
    }
}
