import Foundation

/// CPU-side mirror of `DewarpUniforms` in DewarpShaders.metal — must stay
/// field-for-field identical (order, types) since it's copied in verbatim
/// via `setFragmentBytes`. All plain floats: the UI writes on the main thread,
/// the renderer reads on the display-link thread; worst case is one torn read
/// visible for a single frame, so no lock is needed.
struct DewarpUniformsData {
    var centerX: Float = 0.5
    var centerY: Float = 0.5
    var radius: Float = 0.5
    var lensFOV: Float = FisheyeConfig.reolinkLensFOV
    var outputFOV: Float = 1.66   // ~95° — comfortable virtual camera FOV
    var pan: Float = 0
    var tilt: Float = 0.9         // ~52° from nadir — a natural "looking into the room" start
    var zoom: Float = 1
    var texAspect: Float = 1
    var viewAspect: Float = 1
    var mode: Int32 = DewarpMode.ptz.rawValue
}

/// Presentation modes for a fisheye camera, cycled from the viewer button.
enum DewarpMode: Int32, CaseIterable {
    case off = 0          // passthrough (raw fisheye)
    case panorama = 1     // equirectangular sweep — wide banner of the whole room
    case ptz = 2          // rectilinear virtual PTZ — drag to look around
    case littlePlanet = 3 // stereographic novelty view

    var label: String {
        switch self {
        case .off: return "Raw"
        case .panorama: return "Panorama"
        case .ptz: return "Virtual PTZ"
        case .littlePlanet: return "Little Planet"
        }
    }

    var icon: String {
        switch self {
        case .off: return "circle.dashed"
        case .panorama: return "pano"
        case .ptz: return "arrow.up.and.down.and.arrow.left.and.right"
        case .littlePlanet: return "globe.americas.fill"
        }
    }
}

/// A saved virtual-camera aim — where the user left the view pointed.
struct FisheyePose: Codable, Equatable {
    var pan: Float = 0
    var tilt: Float = 0.9
    var zoom: Float = 1
    var mode: Int32 = DewarpMode.ptz.rawValue

    /// Default aims for the quad view: four compass quadrants of the room.
    static func quadDefault(_ pane: Int) -> FisheyePose {
        FisheyePose(pan: Float(pane) * .pi / 2, tilt: 0.9, zoom: 1, mode: DewarpMode.ptz.rawValue)
    }
}

/// Per-camera fisheye lens calibration + saved view state, persisted by `FisheyeStore`.
struct FisheyeConfig: Codable, Equatable {
    /// Reolink fisheye lens ≈ 200° field of view.
    static let reolinkLensFOV: Float = 3.49

    var centerX: Float = 0.5
    var centerY: Float = 0.5
    var radius: Float = 0.5
    var lensFOV: Float = reolinkLensFOV
    /// Where the single dewarped view was last aimed (viewer AND wall tile restore it).
    var pose: FisheyePose?
    /// PTZ lock — gestures disabled so the saved view can't be nudged accidentally.
    var locked: Bool = false
    /// Verkada-style multi-view: one fisheye split into four independent PTZ panes.
    var quadEnabled: Bool = false
    /// Saved aim of each quad pane (index 0–3).
    var quadPoses: [FisheyePose]?

    init() {}

    // Custom decoding so configs stored by earlier builds (no view-state keys) load cleanly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        centerX = try c.decodeIfPresent(Float.self, forKey: .centerX) ?? 0.5
        centerY = try c.decodeIfPresent(Float.self, forKey: .centerY) ?? 0.5
        radius = try c.decodeIfPresent(Float.self, forKey: .radius) ?? 0.5
        lensFOV = try c.decodeIfPresent(Float.self, forKey: .lensFOV) ?? Self.reolinkLensFOV
        pose = try c.decodeIfPresent(FisheyePose.self, forKey: .pose)
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        quadEnabled = try c.decodeIfPresent(Bool.self, forKey: .quadEnabled) ?? false
        quadPoses = try c.decodeIfPresent([FisheyePose].self, forKey: .quadPoses)
    }
}
