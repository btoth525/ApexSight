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
    /// - Parameter asTest: when true, the notification gets a unique identifier and a short
    ///   trigger so repeated "Send Test Alert" taps each present a fresh banner (a stable
    ///   per-review identifier would otherwise be coalesced/replaced silently by the system).
    static func notify(review: FrigateReviewItem, client: FrigateClient, session: FrigateSession, asTest: Bool = false) async {
        let content = UNMutableNotificationContent()
        content.title = NotificationCopy.title(for: review)
        content.body = NotificationCopy.body(for: review)
        content.sound = .default
        content.threadIdentifier = "apex-\(review.camera)"
        content.categoryIdentifier = NativeNotificationManager.frigateAlertCategory
        // Mark alerts Time Sensitive so they break through a Driving / Do Not Disturb Focus and
        // surface on CarPlay — same as the relay-push path does in the notification-service
        // extension. Needs the time-sensitive entitlement (present). Test pushes too, so a
        // "Send Test Push" while driving proves the CarPlay path.
        content.interruptionLevel = .timeSensitive

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
        var tempURL: URL?
        if let gifURL, let result = await downloadAttachment(url: gifURL, client: client, isGIF: true) {
            content.attachments = [result.attachment]
            tempURL = result.fileURL
        } else if let thumbURL, let result = await downloadAttachment(url: thumbURL, client: client, isGIF: false) {
            content.attachments = [result.attachment]
            tempURL = result.fileURL
        }

        let identifier = asTest ? "apex-test-\(UUID().uuidString)" : "apex-review-\(review.id)"
        let trigger: UNNotificationTrigger? = asTest
            ? UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            : nil

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await UNUserNotificationCenter.current().add(request)

        // The system ingests the attachment into its own store during add(); the source temp
        // file is now safe to delete. (Deleting right after attachment init risks yanking a
        // GIF before the system has copied it.)
        if let tempURL { try? FileManager.default.removeItem(at: tempURL) }
    }

    private static func downloadAttachment(url: URL, client: FrigateClient, isGIF: Bool) async -> (attachment: UNNotificationAttachment, fileURL: URL)? {
        guard let data = try? await client.imageData(from: url), !data.isEmpty else { return nil }
        let ext = isGIF ? "gif" : "jpg"
        let localURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("apex-alert-\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: localURL, options: [.atomic])
            // A type hint makes the system animate GIFs reliably in the expanded view.
            let options: [String: Any]? = isGIF
                ? [UNNotificationAttachmentOptionsTypeHintKey: UTType.gif.identifier]
                : nil
            let attachment = try UNNotificationAttachment(identifier: UUID().uuidString, url: localURL, options: options)
            return (attachment, localURL)
        } catch {
            try? FileManager.default.removeItem(at: localURL)
            return nil
        }
    }
}
