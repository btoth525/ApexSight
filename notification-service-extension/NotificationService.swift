import UserNotifications

/// Notification Service Extension — Apex Sight
///
/// iOS calls this before displaying any push notification that carries
/// "mutable-content": 1 in the APNs payload (Expo sets this when
/// mutableContent:true is passed to the push gateway). We download the
/// snapshot image and attach it so it appears on the lock screen even
/// when the main app is fully killed.
///
/// Payload path (Expo maps push `data` → APNs `body` in userInfo):
///   userInfo["body"]["image"]           ← primary (our server sends this)
///   userInfo["attachment-url"]          ← Home Assistant compat
///   …additional fallbacks below
///
/// Auth: the main app writes frigate_token into the shared App Group
/// (group.com.brandontoth.apexsight) so the extension can attach it as
/// a Cookie when the image URL requires authentication.

class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttempt: UNMutableNotificationContent?

    private let appGroupId = "group.com.brandontoth.apexsight"

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

        guard
            let imageUrlString = extractImageUrl(from: bestAttempt.userInfo),
            let imageUrl = URL(string: imageUrlString)
        else {
            contentHandler(bestAttempt)
            return
        }

        // Read auth token from App Group UserDefaults (written by main app on login)
        let token = UserDefaults(suiteName: appGroupId)?.string(forKey: "frigate_token")

        downloadAndAttach(url: imageUrl, token: token, content: bestAttempt) { final in
            contentHandler(final)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler = contentHandler, let content = bestAttempt {
            handler(content)
        }
    }

    // MARK: - Payload parsing

    private func extractImageUrl(from userInfo: [AnyHashable: Any]) -> String? {
        // 1. Home Assistant top-level key
        if let url = userInfo["attachment-url"] as? String, !url.isEmpty { return url }

        // 2. Expo push: `data` dict → appears as `body` in APNs userInfo
        if let body = userInfo["body"] as? [String: Any] {
            // Primary — our server puts the URL at data["image"]
            if let url = body["image"]      as? String, !url.isEmpty { return url }
            if let url = body["imageUrl"]   as? String, !url.isEmpty { return url }
            if let url = body["attachment_url"] as? String, !url.isEmpty { return url }
            // Expo rich-content arrays
            if let atts = body["attachments"] as? [[String: Any]],
               let url  = atts.first?["url"] as? String, !url.isEmpty { return url }
            if let rich = body["richContent"] as? [String: Any],
               let url  = rich["image"] as? String, !url.isEmpty { return url }
            // Double-nested fallback
            if let nested = body["data"] as? [String: Any] {
                if let url = nested["image"]    as? String, !url.isEmpty { return url }
                if let url = nested["imageUrl"] as? String, !url.isEmpty { return url }
            }
        }

        // 3. Top-level fallbacks (in case keys passed through directly)
        if let url = userInfo["image"]    as? String, !url.isEmpty { return url }
        if let url = userInfo["imageUrl"] as? String, !url.isEmpty { return url }
        if let atts = userInfo["attachments"] as? [[String: Any]],
           let url  = atts.first?["url"] as? String, !url.isEmpty { return url }

        return nil
    }

    // MARK: - Download & attach

    private func downloadAndAttach(
        url: URL,
        token: String?,
        content: UNMutableNotificationContent,
        completion: @escaping (UNNotificationContent) -> Void
    ) {
        var req = URLRequest(url: url, timeoutInterval: 25)
        if let t = token, !t.isEmpty {
            req.setValue("frigate_token=\(t)", forHTTPHeaderField: "Cookie")
        }

        URLSession.shared.downloadTask(with: req) { localUrl, response, error in
            defer { completion(content) }
            guard error == nil, let localUrl = localUrl else { return }
            // Don't attach error pages
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 { return }

            let tmp = FileManager.default.temporaryDirectory
            let ext = self.fileExtension(for: url, response: response)
            let dest = tmp.appendingPathComponent("\(UUID().uuidString).\(ext)")
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: localUrl, to: dest)
                content.attachments = [try UNNotificationAttachment(
                    identifier: "snapshot", url: dest, options: nil
                )]
            } catch {}
        }.resume()
    }

    private func fileExtension(for url: URL, response: URLResponse?) -> String {
        let mime = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if mime.contains("png")  { return "png"  }
        if mime.contains("webp") { return "webp" }
        if mime.contains("gif")  { return "gif"  }
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "jpg" : ext
    }
}
