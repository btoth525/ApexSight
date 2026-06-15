import Foundation
import UserNotifications

/// Posts a local notification for a Frigate review that mirrors the remote-push
/// contract exactly: same copy, category, and userInfo keys the
/// NotificationResponseDelegate already routes (`review_id`, `camera`, `apex_url`,
/// `frigate_token`, `snapshot_url`). Local notifications don't run the service
/// extension, so the snapshot is downloaded and attached in-process here.
enum LocalAlertNotifier {
    static func notify(review: FrigateReviewItem, client: FrigateClient, session: FrigateSession) async {
        let content = UNMutableNotificationContent()
        content.title = NotificationCopy.title(for: review)
        content.body = NotificationCopy.body(for: review)
        content.sound = .default
        content.threadIdentifier = "apex-\(review.camera)"
        content.categoryIdentifier = NativeNotificationManager.frigateAlertCategory

        // Prefer the first detection's snapshot; fall back to its cropped thumbnail.
        let snapshotURL = client.reviewSnapshotURL(review: review)
            ?? client.reviewThumbnailURL(review: review)
        var userInfo: [String: Any] = [
            "review_id": review.id,
            "camera": review.camera,
            "apex_url": "apex://review?id=\(review.id)",
            "frigate_token": session.token
        ]
        if let snapshotURL {
            userInfo["snapshot_url"] = snapshotURL.absoluteString
        }
        content.userInfo = userInfo

        if let snapshotURL, let attachment = await downloadAttachment(url: snapshotURL, client: client) {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(
            identifier: "apex-review-\(review.id)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func downloadAttachment(url: URL, client: FrigateClient) async -> UNNotificationAttachment? {
        guard let data = try? await client.imageData(from: url) else { return nil }
        let localURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("apex-alert-\(UUID().uuidString).jpg")
        do {
            try data.write(to: localURL, options: [.atomic])
            return try UNNotificationAttachment(identifier: "frigate-snapshot", url: localURL)
        } catch {
            return nil
        }
    }
}
