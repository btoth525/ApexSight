import CoreGraphics
import Testing
@testable import ApexSightNative

/// Regression guards for the live detection overlay's coordinate math.
///
/// The shipped bug: `FrigateEvent.frameWidth`/`frameHeight` map to top-level `width`/`height`
/// keys that Frigate 0.18's WebSocket payload does not send (measured: 81 consecutive live
/// `events` frames, zero occurrences), so the old inline guard rejected every detection and the
/// overlay was dead on every camera in every session. The fix falls back to the camera's
/// configured detect resolution, which is the frame `box` is already expressed in.
///
/// These pin both directions: the fallback must actually produce a box, and every untrustworthy
/// input must still produce nothing rather than a stray marker on a security feed.
@Suite("DetectionBox")
struct DetectionBoxTests {

    // MARK: - The real measured payloads

    @Test("Normalizes a live Living_Room_Wide box against its 640x360 detect frame")
    func livingRoomWide() throws {
        // Captured live: box [462, 241, 565, 358], camera detect 640x360.
        let rect = try #require(DetectionBox.normalized(box: [462, 241, 565, 358],
                                                        frameWidth: 640,
                                                        frameHeight: 360))
        #expect(abs(rect.minX - 462.0 / 640.0) < 0.0001)
        #expect(abs(rect.minY - 241.0 / 360.0) < 0.0001)
        #expect(abs(rect.width - 103.0 / 640.0) < 0.0001)
        #expect(abs(rect.height - 117.0 / 360.0) < 0.0001)
    }

    @Test("Normalizes a live Front_Driveway box against its non-16:9 1536x432 detect frame")
    func frontDriveway() throws {
        // Captured live: box [599, 23, 630, 92], camera detect 1536x432 (ultra-wide).
        let rect = try #require(DetectionBox.normalized(box: [599, 23, 630, 92],
                                                        frameWidth: 1536,
                                                        frameHeight: 432))
        #expect(abs(rect.minX - 599.0 / 1536.0) < 0.0001)
        #expect(abs(rect.height - 69.0 / 432.0) < 0.0001)
    }

    @Test("A box spanning the whole detect frame normalizes to the unit rect")
    func fullFrame() throws {
        let rect = try #require(DetectionBox.normalized(box: [0, 0, 640, 360],
                                                        frameWidth: 640,
                                                        frameHeight: 360))
        #expect(rect == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    // MARK: - Fail-quiet: nothing drawn beats something wrong

    @Test("No frame size means no box — the regression that made the overlay dead")
    func missingFrameSize() {
        #expect(DetectionBox.normalized(box: [462, 241, 565, 358],
                                        frameWidth: nil, frameHeight: nil) == nil)
        #expect(DetectionBox.normalized(box: [462, 241, 565, 358],
                                        frameWidth: 640, frameHeight: nil) == nil)
        #expect(DetectionBox.normalized(box: [462, 241, 565, 358],
                                        frameWidth: nil, frameHeight: 360) == nil)
    }

    @Test("A missing or short box yields nothing")
    func malformedBox() {
        #expect(DetectionBox.normalized(box: nil, frameWidth: 640, frameHeight: 360) == nil)
        #expect(DetectionBox.normalized(box: [], frameWidth: 640, frameHeight: 360) == nil)
        #expect(DetectionBox.normalized(box: [1, 2, 3], frameWidth: 640, frameHeight: 360) == nil)
        #expect(DetectionBox.normalized(box: [1, 2, 3, 4, 5], frameWidth: 640, frameHeight: 360) == nil)
    }

    @Test("A zero or negative frame size can never divide")
    func degenerateFrameSize() {
        #expect(DetectionBox.normalized(box: [0, 0, 10, 10], frameWidth: 0, frameHeight: 360) == nil)
        #expect(DetectionBox.normalized(box: [0, 0, 10, 10], frameWidth: 640, frameHeight: 0) == nil)
        #expect(DetectionBox.normalized(box: [0, 0, 10, 10], frameWidth: -640, frameHeight: 360) == nil)
    }

    @Test("An inverted or zero-area box draws nothing rather than a stray marker")
    func degenerateBox() {
        // x2 < x1
        #expect(DetectionBox.normalized(box: [500, 10, 100, 200], frameWidth: 640, frameHeight: 360) == nil)
        // y2 < y1
        #expect(DetectionBox.normalized(box: [10, 300, 200, 100], frameWidth: 640, frameHeight: 360) == nil)
        // zero area
        #expect(DetectionBox.normalized(box: [100, 100, 100, 100], frameWidth: 640, frameHeight: 360) == nil)
    }

    @Test("Non-finite inputs are rejected, never turned into a NaN rect")
    func nonFinite() {
        #expect(DetectionBox.normalized(box: [.nan, 0, 100, 100], frameWidth: 640, frameHeight: 360) == nil)
        #expect(DetectionBox.normalized(box: [0, 0, .infinity, 100], frameWidth: 640, frameHeight: 360) == nil)
        #expect(DetectionBox.normalized(box: [0, 0, 100, 100], frameWidth: .nan, frameHeight: 360) == nil)
        #expect(DetectionBox.normalized(box: [0, 0, 100, 100], frameWidth: 640, frameHeight: .infinity) == nil)
    }
}
