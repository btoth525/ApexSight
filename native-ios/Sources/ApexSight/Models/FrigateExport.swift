import Foundation

/// A recording Frigate has exported (or is exporting) to a downloadable MP4. Rendered server-side
/// by ffmpeg, so it exists for every camera regardless of resolution/codec.
struct FrigateExport: Identifiable, Codable, Hashable {
    let id: String
    let camera: String
    let name: String
    let date: Double?
    /// Internal path, e.g. `/media/frigate/exports/Front_Driveway_…_id.mp4`. The served file is at
    /// `/exports/<filename>` — see `filename` and `FrigateClient.exportFileURL`.
    let videoPath: String?
    let thumbPath: String?
    /// True while Frigate is still rendering; the file isn't downloadable yet.
    let inProgress: Bool?

    /// The bare filename Frigate serves under `/exports/`.
    var filename: String? {
        videoPath.map { ($0 as NSString).lastPathComponent }
    }

    var createdAt: Date? { date.map { Date(timeIntervalSince1970: $0) } }
    var isReady: Bool { (inProgress ?? false) == false && filename != nil }

    enum CodingKeys: String, CodingKey {
        case id, camera, name, date
        case videoPath = "video_path"
        case thumbPath = "thumb_path"
        case inProgress = "in_progress"
    }
}
