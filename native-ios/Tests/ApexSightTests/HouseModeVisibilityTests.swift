import Testing
@testable import ApexSightNative

/// Regression guards for the house-mode camera-visibility filter that also drives the
/// unreviewed badge count (`AppState.unreviewedCount` filters on this same function). FAIL-OPEN
/// is the invariant: a miss must always show/count the camera, never hide it.
@Suite("HouseModeVisibility")
struct HouseModeVisibilityTests {
    @Test("Empty mute list shows every camera")
    func emptyMuteListShowsAll() {
        #expect(HouseModeVisibility.cameraVisible("front_door", mutedCameras: [], showAll: false))
    }

    @Test("A camera in the mute list is hidden")
    func mutedCameraHidden() {
        #expect(!HouseModeVisibility.cameraVisible("garage", mutedCameras: ["garage", "backyard"], showAll: false))
    }

    @Test("A camera not in the mute list is shown")
    func unmutedCameraShown() {
        #expect(HouseModeVisibility.cameraVisible("front_door", mutedCameras: ["garage", "backyard"], showAll: false))
    }

    @Test("showAll overrides an active mute")
    func showAllOverridesMute() {
        #expect(HouseModeVisibility.cameraVisible("garage", mutedCameras: ["garage"], showAll: true))
    }

    @Test("Matching is case-insensitive")
    func caseInsensitiveMatch() {
        #expect(!HouseModeVisibility.cameraVisible("Garage", mutedCameras: ["garage"], showAll: false))
        #expect(!HouseModeVisibility.cameraVisible("garage", mutedCameras: ["GARAGE"], showAll: false))
    }

    @Test("An empty camera name fails open (shown)")
    func emptyCameraNameFailsOpen() {
        #expect(HouseModeVisibility.cameraVisible("", mutedCameras: ["garage"], showAll: false))
    }
}
