import Foundation
import Testing
@testable import ApexSightNative

/// The widget, the Watch feed and Siri's "latest alert" are written from extension processes that
/// cannot see `AppState`, so the only way they can honour a house-mode mute is the app-group
/// mirror. These pin the two things that silently break it:
///
///  • a drifted key — `showAllCameras` MUST keep reading the exact string the app has always
///    persisted `showAllCamerasInFeeds` under, or every user's escape-hatch preference resets to
///    off on upgrade and never round-trips again;
///  • a mirror that doesn't fail open — an extension that has never seen a write must show
///    everything, never silently hide a camera.
@Suite("SharedHouseMode mirror", .serialized)
struct SharedHouseModeMirrorTests {
    private var defaults: UserDefaults? { UserDefaults(suiteName: ApexAppGroup.identifier) }

    /// Restores whatever the device really had, so running tests can't silently mute a camera.
    private func withRestoredMirror(_ body: () -> Void) {
        let mutes = SharedHouseMode.mutedCameras
        let showAll = SharedHouseMode.showAllCameras
        defer {
            SharedHouseMode.mutedCameras = mutes
            SharedHouseMode.showAllCameras = showAll
        }
        body()
    }

    @Test("Muted-camera list round-trips through the app group")
    func mutesRoundTrip() {
        withRestoredMirror {
            SharedHouseMode.mutedCameras = ["Living_Room_Wide", "zachs_room"]
            #expect(SharedHouseMode.mutedCameras == ["Living_Room_Wide", "zachs_room"])
            SharedHouseMode.mutedCameras = []
            #expect(SharedHouseMode.mutedCameras.isEmpty)
        }
    }

    @Test("showAllCameras keeps the legacy key, so an existing preference survives")
    func showAllUsesLegacyKey() {
        withRestoredMirror {
            // The key AppState persisted by hand before SharedHouseMode owned it.
            defaults?.set(true, forKey: "apex.showAllCamerasInFeeds")
            #expect(SharedHouseMode.showAllCameras)

            SharedHouseMode.showAllCameras = false
            #expect(defaults?.bool(forKey: "apex.showAllCamerasInFeeds") == false)
        }
    }

    @Test("An extension that has never seen a write fails OPEN")
    func unwrittenMirrorFailsOpen() {
        withRestoredMirror {
            defaults?.removeObject(forKey: "apex.houseModeMutedCameras")
            defaults?.removeObject(forKey: "apex.showAllCamerasInFeeds")
            #expect(SharedHouseMode.mutedCameras.isEmpty)
            #expect(SharedHouseMode.showAllCameras == false)
            // Empty mutes + showAll off is exactly the "show everything" answer.
            #expect(HouseModeVisibility.cameraVisible("Living_Room_Wide",
                                                      mutedCameras: SharedHouseMode.mutedCameras,
                                                      showAll: SharedHouseMode.showAllCameras))
        }
    }

    @Test("A mirrored mute hides that camera from the widget feed, and only that camera")
    func mirroredMuteFiltersTheFeed() {
        withRestoredMirror {
            SharedHouseMode.mutedCameras = ["Living_Room_Wide", "Garage"]
            SharedHouseMode.showAllCameras = false

            // The exact camera mix the live server returns for the widget's own query.
            let feed = ["Garage", "Front_Driveway", "Living_Room_Wide", "Garage", "Front_Driveway"]
            let visible = feed.filter {
                HouseModeVisibility.cameraVisible($0,
                                                  mutedCameras: SharedHouseMode.mutedCameras,
                                                  showAll: SharedHouseMode.showAllCameras)
            }
            #expect(visible == ["Front_Driveway", "Front_Driveway"])
        }
    }

    /// The widget FETCHES a page and only then applies the mute, so the page has to be bigger than
    /// the feed. Measured on the live server: the newest 8 un-reviewed reviews were ALL from
    /// cameras that Home/Night mute, while the newest 40 still left 16 visible. Filtering a page of
    /// 8 would therefore have written "all clear" to the Lock Screen with a driveway alert sitting
    /// at position 9 — a security app affirmatively reporting nothing happened.
    @Test("A page smaller than the feed starves it; the real fetch window does not")
    func fetchWindowLeavesHeadroom() {
        withRestoredMirror {
            SharedHouseMode.mutedCameras = ["Living_Room_Wide", "Garage", "movie_room"]
            SharedHouseMode.showAllCameras = false

            // The live ordering: the first 8 are all muted, driveway activity starts after them.
            let page = ["Living_Room_Wide", "Living_Room_Wide", "movie_room", "movie_room",
                        "movie_room", "Garage", "Living_Room_Wide", "Garage"]
                + Array(repeating: "Front_Driveway", count: 8)
                + Array(repeating: "Side_Gate", count: 5)

            func feed(fetching window: Int, showing count: Int) -> [String] {
                page.prefix(window)
                    .filter {
                        HouseModeVisibility.cameraVisible($0,
                                                          mutedCameras: SharedHouseMode.mutedCameras,
                                                          showAll: SharedHouseMode.showAllCameras)
                    }
                    .prefix(count)
                    .map { $0 }
            }

            // The regression: fetching exactly the display count yields a FALSE all-clear.
            #expect(feed(fetching: 8, showing: 8).isEmpty)
            // The shipped window backfills past the muted run and fills the feed.
            #expect(feed(fetching: 40, showing: 8).count == 8)
            #expect(feed(fetching: 40, showing: 8).allSatisfy { $0 == "Front_Driveway" })
        }
    }

    @Test("The user's show-all escape hatch defeats the mirror, as in the app")
    func showAllDefeatsTheMirror() {
        withRestoredMirror {
            SharedHouseMode.mutedCameras = ["Living_Room_Wide"]
            SharedHouseMode.showAllCameras = true
            #expect(HouseModeVisibility.cameraVisible("Living_Room_Wide",
                                                      mutedCameras: SharedHouseMode.mutedCameras,
                                                      showAll: SharedHouseMode.showAllCameras))
        }
    }
}
