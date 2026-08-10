import Foundation

/// Turns a notification response into the `apex://` link it should open.
///
/// Extracted as a pure function for one reason: the same decision has to be made twice. Normally
/// `NotificationResponseDelegate` routes straight through `AppState.handleDeepLink`, but on a cold
/// launch the delegate's `Task { @MainActor … }` can run before `RootView.onAppear` has handed it
/// an AppState — and the delegate's own comment says the view hierarchy mounts too late. In that
/// window the tap used to be discarded outright; now it is stashed in the app group and drained by
/// `AppState.consumePendingIntentLink()`. Both paths must pick the SAME destination, so they share
/// this one.
///
/// The precedence below is the shipped routing, unchanged:
///  • "View Live" → the camera;
///  • "Review" → the review, else the payload's own link, else the camera (explicit, so the action
///    can never dead-end regardless of which fields the payload carries);
///  • a plain tap → the payload's own link, else review, else event, else camera.
enum NotificationDeepLink {

    static func link(action: String, userInfo: [AnyHashable: Any]) -> URL? {
        let camera = nonEmpty(userInfo["camera"])
        let reviewID = nonEmpty(userInfo["review_id"])
        let eventID = nonEmpty(userInfo["event_id"])
        let payloadLink = nonEmpty(userInfo["apex_url"]).flatMap(URL.init(string:))

        if action == NativeNotificationManager.viewLiveAction, let camera {
            return make(host: "camera", query: "name", value: camera)
        }

        if action == NativeNotificationManager.openReviewAction {
            if let reviewID { return make(host: "review", query: "id", value: reviewID) }
            if let payloadLink { return payloadLink }
            if let camera { return make(host: "camera", query: "name", value: camera) }
            return nil
        }

        if let payloadLink { return payloadLink }
        if let reviewID { return make(host: "review", query: "id", value: reviewID) }
        if let eventID { return make(host: "event", query: "id", value: eventID) }
        if let camera { return make(host: "camera", query: "name", value: camera) }
        return nil
    }

    private static func make(host: String, query: String, value: String) -> URL? {
        var components = URLComponents()
        components.scheme = "apex"
        components.host = host
        components.queryItems = [URLQueryItem(name: query, value: value)]
        return components.url
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
