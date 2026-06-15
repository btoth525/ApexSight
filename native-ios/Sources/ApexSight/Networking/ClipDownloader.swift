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

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(fileName)
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
