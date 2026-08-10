import Foundation
import Testing
import UserNotifications
@testable import ApexSightNative

/// A tapped alert is the whole point of this app, so the routing it produces is pinned here.
/// Two consumers depend on it agreeing with itself: the live path (AppState.handleDeepLink) and
/// the cold-launch stash written to `apex.pendingIntentLink` when the delegate fires before
/// RootView.onAppear has handed it an AppState. If they ever disagree, a push tap opens the wrong
/// thing on cold launch and the right thing when warm — the hardest kind of bug to notice.
@Suite("Notification deep link routing")
struct NotificationDeepLinkTests {
    private let viewLive = NativeNotificationManager.viewLiveAction
    private let openReview = NativeNotificationManager.openReviewAction
    private let tap = UNNotificationDefaultActionIdentifier

    private func link(_ action: String, _ userInfo: [AnyHashable: Any]) -> String? {
        NotificationDeepLink.link(action: action, userInfo: userInfo)?.absoluteString
    }

    // MARK: - Plain tap

    @Test("A plain tap prefers the payload's own link")
    func tapPrefersPayloadLink() {
        let info: [AnyHashable: Any] = [
            "apex_url": "apex://review?id=1786.5-abc",
            "review_id": "other", "camera": "Garage"
        ]
        #expect(link(tap, info) == "apex://review?id=1786.5-abc")
    }

    @Test("Then review, then event, then camera")
    func tapPrecedence() {
        #expect(link(tap, ["review_id": "1786.5-abc", "event_id": "e", "camera": "Garage"])
                == "apex://review?id=1786.5-abc")
        #expect(link(tap, ["event_id": "1.2-a", "camera": "Garage"])
                == "apex://event?id=1.2-a")
        #expect(link(tap, ["camera": "Front_Driveway"])
                == "apex://camera?name=Front_Driveway")
    }

    @Test("A payload with nothing routable yields no link rather than a bogus one")
    func nothingRoutable() {
        #expect(link(tap, [:]) == nil)
        #expect(link(tap, ["label": "person", "score": 0.9]) == nil)
    }

    @Test("Empty strings count as absent, so an empty review_id falls through to the camera")
    func emptyValuesIgnored() {
        #expect(link(tap, ["review_id": "", "camera": "Garage"]) == "apex://camera?name=Garage")
        #expect(link(tap, ["apex_url": "", "review_id": "r"]) == "apex://review?id=r")
    }

    // MARK: - Action buttons

    @Test("View Live goes to the camera even when a review id is present")
    func viewLiveWinsOnCamera() {
        #expect(link(viewLive, ["camera": "Side_Gate", "review_id": "r"])
                == "apex://camera?name=Side_Gate")
    }

    @Test("View Live with no camera falls through to the normal precedence rather than dead-ending")
    func viewLiveWithoutCameraFallsThrough() {
        #expect(link(viewLive, ["review_id": "1786.5-abc"]) == "apex://review?id=1786.5-abc")
    }

    @Test("Review opens the review, else the payload link, else the camera — never nothing-when-it-could")
    func reviewActionPrecedence() {
        #expect(link(openReview, ["review_id": "r", "apex_url": "apex://camera?name=Garage"])
                == "apex://review?id=r")
        #expect(link(openReview, ["apex_url": "apex://event?id=e", "camera": "Garage"])
                == "apex://event?id=e")
        #expect(link(openReview, ["camera": "Garage"]) == "apex://camera?name=Garage")
        #expect(link(openReview, ["event_id": "e"]) == nil)
    }

    // MARK: - Encoding

    @Test("A camera name needing escaping produces a URL that parses back to the same name")
    func percentEncoding() {
        guard let url = NotificationDeepLink.link(action: tap, userInfo: ["camera": "Back Yard & Gate"]) else {
            Issue.record("expected a link")
            return
        }
        let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "name" }?.value
        #expect(name == "Back Yard & Gate")
        #expect(url.scheme == "apex")
    }

    @Test("Real Frigate ids survive the round trip unmangled")
    func realIDsRoundTrip() {
        let id = "1786200060.753089-jego7p"
        guard let url = NotificationDeepLink.link(action: tap, userInfo: ["review_id": id]) else {
            Issue.record("expected a link")
            return
        }
        let parsed = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "id" }?.value
        #expect(parsed == id)
    }

    @Test("Non-string payload values can't produce a malformed link")
    func nonStringValuesIgnored() {
        #expect(link(tap, ["review_id": 42, "camera": ["a"]]) == nil)
    }
}
