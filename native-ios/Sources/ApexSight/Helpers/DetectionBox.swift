import CoreGraphics
import Foundation

/// Turns a Frigate tracked-object bounding box into the 0–1 normalized rect the live overlay draws.
///
/// Frigate's WebSocket `events` payload gives `box` as `[x1, y1, x2, y2]` in **detect-frame
/// pixels**, and the divisor is that camera's `detect` resolution from `/api/config`.
///
/// Measured against the live server (Frigate 0.18, 81 consecutive `events` frames): not one frame
/// carried a top-level `width` or `height` key, so `FrigateEvent.frameWidth`/`frameHeight` — which
/// map to exactly those keys — are always nil in practice and the overlay could never resolve a
/// box. Sample: `Living_Room_Wide box [462, 241, 565, 358]` against that camera's configured
/// `detect: 640x360`, and `Front_Driveway box [599, 23, 630, 92]` against `detect: 1536x432` —
/// pixel coordinates that fit their camera's detect frame exactly.
///
/// **Fail-quiet**: any input that can't be trusted returns nil, meaning "draw nothing". A missing
/// frame size, a short box, or a degenerate/inverted rect must never produce a box floating over
/// the wrong part of a security camera's picture.
enum DetectionBox {

    /// The normalized 0–1 rect for a detection, or nil when it can't be resolved.
    ///
    /// - Parameters:
    ///   - box: the event's `box`, `[x1, y1, x2, y2]` in detect-frame pixels.
    ///   - frameWidth: the frame width those pixels are expressed in — the event's own `width`
    ///     when the server sends one, else the camera's configured detect width.
    ///   - frameHeight: likewise for height.
    static func normalized(box: [Double]?, frameWidth: Double?, frameHeight: Double?) -> CGRect? {
        guard let box, box.count == 4,
              let w = frameWidth, w.isFinite, w > 0,
              let h = frameHeight, h.isFinite, h > 0,
              box.allSatisfy({ $0.isFinite }) else { return nil }

        let width = (box[2] - box[0]) / w
        let height = (box[3] - box[1]) / h
        // An inverted or zero-area box is nonsense, not a hint — drawing it would put a stray
        // marker on the feed. Nothing rendered at all is the safer answer.
        guard width > 0, height > 0 else { return nil }

        return CGRect(x: box[0] / w, y: box[1] / h, width: width, height: height)
    }
}
