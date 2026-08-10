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
        let mode = SharedHouseMode.mode
        let mutes = SharedHouseMode.mutedCameras
        let showAll = SharedHouseMode.showAllCameras
        defer {
            SharedHouseMode.setMutedCameras(mutes, for: mode)
            SharedHouseMode.mode = mode
            SharedHouseMode.showAllCameras = showAll
        }
        body()
    }

    /// Put the mirror in the state it has after a successful relay poll: a mute list stamped with
    /// the mode currently in force.
    private func mirror(mutes: [String], mode: String = "home") {
        SharedHouseMode.mode = mode
        SharedHouseMode.setMutedCameras(mutes, for: mode)
    }

    @Test("Muted-camera list round-trips through the app group")
    func mutesRoundTrip() {
        withRestoredMirror {
            mirror(mutes: ["Living_Room_Wide", "zachs_room"])
            #expect(SharedHouseMode.mutedCameras == ["Living_Room_Wide", "zachs_room"])
            mirror(mutes: [])
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
            mirror(mutes: ["Living_Room_Wide", "Garage"])
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
            mirror(mutes: ["Living_Room_Wide", "Garage", "movie_room"])
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

    /// `SharedHouseMode.mode` is written from THREE places, two of which (`SharedHouseModeFetch`,
    /// `SharedRelayGate`) run in extension processes that cannot see `AppState` and so cannot
    /// refresh the mute list. Before the stamp, a mode change while the app was closed left the
    /// widget filtering the feed by the PREVIOUS mode's mutes — hiding alerts from cameras the new
    /// mode does not silence at all. Hiding a real alert is the one direction this app must never
    /// fail in, so a stamp mismatch reads as "no mutes known": show everything.
    @Test("A mute list left over from another mode is ignored, not applied")
    func staleMuteListFailsOpen() {
        withRestoredMirror {
            SharedHouseMode.showAllCameras = false
            mirror(mutes: ["Front_Driveway"], mode: "home")
            #expect(SharedHouseMode.mutedCameras == ["Front_Driveway"])

            // Alarmo flips the house to away while the app is closed; an extension updates the mode.
            SharedHouseMode.mode = "away"
            #expect(SharedHouseMode.mutedCameras.isEmpty)
            #expect(HouseModeVisibility.cameraVisible("Front_Driveway",
                                                      mutedCameras: SharedHouseMode.mutedCameras,
                                                      showAll: SharedHouseMode.showAllCameras))

            // Once the relay is read for the new mode, its own list applies again.
            SharedHouseMode.setMutedCameras(["Living_Room_Wide"], for: "away")
            #expect(SharedHouseMode.mutedCameras == ["Living_Room_Wide"])
            #expect(HouseModeVisibility.cameraVisible("Front_Driveway",
                                                      mutedCameras: SharedHouseMode.mutedCameras,
                                                      showAll: SharedHouseMode.showAllCameras))
        }
    }

    @Test("The user's show-all escape hatch defeats the mirror, as in the app")
    func showAllDefeatsTheMirror() {
        withRestoredMirror {
            mirror(mutes: ["Living_Room_Wide"])
            SharedHouseMode.showAllCameras = true
            #expect(HouseModeVisibility.cameraVisible("Living_Room_Wide",
                                                      mutedCameras: SharedHouseMode.mutedCameras,
                                                      showAll: SharedHouseMode.showAllCameras))
        }
    }
}
