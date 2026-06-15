import Foundation
import UniformTypeIdentifiers
import UserNotifications

/// Posts a local notification for a Frigate review that mirrors the remote-push
/// contract exactly: same copy, category, and userInfo keys the
/// NotificationResponseDelegate already routes (`review_id`, `camera`, `apex_url`,
/// `frigate_token`, `snapshot_url`). Local notifications don't run the service
/// extension, so the media is downloaded and attached in-process here.
///
/// The attachment is an animated GIF of the event (Frigate's `preview.gif`) so the
/// expanded notification plays back what happened; it falls back to the cropped
/// detection thumbnail when a GIF isn't available yet.
enum LocalAlertNotifier {
    static func notify(review: FrigateReviewItem, client: FrigateClient, session: FrigateSession) async {
        let content = UNMutableNotificationContent()
        content.title = NotificationCopy.title(for: review)
        content.body = NotificationCopy.body(for: review)
        content.sound = .default
        content.threadIdentifier = "apex-\(review.camera)"
        content.categoryIdentifier = NativeNotificationManager.frigateAlertCategory

        let gifURL = client.reviewGifURL(review: review)
        let thumbURL = client.reviewSnapshotURL(review: review) ?? client.reviewThumbnailURL(review: review)

        var userInfo: [String: Any] = [
            "review_id": review.id,
            "camera": review.camera,
            "apex_url": "apex://review?id=\(review.id)",
            "frigate_token": session.token
        ]
        // Prefer the animated GIF for the remote-push path too; keep a static fallback.
        if let gifURL { userInfo["snapshot_url"] = gifURL.absoluteString }
        if let thumbURL { userInfo["thumbnail_url"] = thumbURL.absoluteString }
        content.userInfo = userInfo

        // Try the animated GIF first, then the static thumbnail.
        if let gifURL, let attachment = await downloadAttachment(url: gifURL, client: client, isGIF: true) {
            content.attachments = [attachment]
        } else if let thumbURL, let attachment = await downloadAttachment(url: thumbURL, client: client, isGIF: false) {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(
            identifier: "apex-review-\(review.id)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func downloadAttachment(url: URL, client: FrigateClient, isGIF: Bool) async -> UNNotificationAttachment? {
        guard let data = try? await client.imageData(from: url), !data.isEmpty else { return nil }
        let ext = isGIF ? "gif" : "jpg"
        let localURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("apex-alert-\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: localURL, options: [.atomic])
            let options: [String: Any]? = isGIF
                ? [UNNotificationAttachmentOptionsTypeHintKey: UTType.gif.identifier]
                : nil
            return try UNNotificationAttachment(identifier: "frigate-media", url: localURL, options: options)
        } catch {
            return nil
        }
    }
}
