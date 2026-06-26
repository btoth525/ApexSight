import Foundation
import Photos

enum ClipDownloadError: LocalizedError {
    case noConnection
    case writeFailed
    case photoPermissionDenied

    var errorDescription: String? {
        switch self {
        case .noConnection: return "No Frigate connection."
        case .writeFailed: return "Could not save the clip file."
        case .photoPermissionDenied: return "Allow photo access in Settings to save clips."
        }
    }
}

/// Downloads an authenticated Frigate MP4 clip to a temporary file and saves it to the Photos library.
@MainActor
enum ClipDownloader {
    static func downloadToPhotos(url: URL, client: FrigateClient, fileName: String) async throws {
        let data = try await client.imageData(from: url)

        // Camera names come from arbitrary Frigate config, so a "/" (or ":") in the name would
        // turn the file component into a non-existent subpath and fail the write. Flatten any
        // path separators to keep the temp file a single valid component.
        let safeName = fileName.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(safeName)
            .appendingPathExtension("mp4")
        do {
            try data.write(to: tempURL, options: .atomic)
        } catch {
            throw ClipDownloadError.writeFailed
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let status = await requestAddPermission()
        guard status == .authorized || status == .limited else {
            throw ClipDownloadError.photoPermissionDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: tempURL)
        }
    }

    private static func requestAddPermission() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current == .notDetermined {
            return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        return current
    }
}
