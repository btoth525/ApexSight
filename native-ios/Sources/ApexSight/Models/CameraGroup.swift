import Foundation

/// A user-defined set of cameras shown together in the multi-camera wall.
struct CameraGroup: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var cameraNames: [String]
    var columns: Int = 2
}
