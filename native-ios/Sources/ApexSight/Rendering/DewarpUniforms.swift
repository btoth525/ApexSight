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

/// Per-camera fisheye lens calibration, persisted by `FisheyeStore`.
struct FisheyeConfig: Codable, Equatable {
    /// Reolink fisheye lens ≈ 200° field of view.
    static let reolinkLensFOV: Float = 3.49

    var centerX: Float = 0.5
    var centerY: Float = 0.5
    var radius: Float = 0.5
    var lensFOV: Float = reolinkLensFOV
}
