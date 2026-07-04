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
/// Clips stream straight to disk via `FrigateClient.downloadClipFile` — never buffered whole in
/// memory, and on the long-timeout download session so big exports over slow links survive.
@MainActor
enum ClipDownloader {
    static func downloadToPhotos(url: URL, client: FrigateClient, fileName: String) async throws {
        let tempURL = try await client.downloadClipFile(from: url, suggestedName: fileName)
        // Remove the whole per-call directory (downloadClipFile wraps each file in one).
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }

        let status = await requestAddPermission()
        guard status == .authorized || status == .limited else {
            throw ClipDownloadError.photoPermissionDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: tempURL)
        }
    }

    /// Download an authenticated Frigate MP4 to a temp file and return its URL for sharing
    /// (AirDrop / Messages / Files). Unlike `downloadToPhotos` it needs no photo permission and
    /// does NOT delete the file — the share sheet reads it after this returns. The OS clears the
    /// temp directory later.
    static func downloadToTempFile(url: URL, client: FrigateClient, fileName: String) async throws -> URL {
        try await client.downloadClipFile(from: url, suggestedName: fileName)
    }

    private static func requestAddPermission() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current == .notDetermined {
            return await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        return current
    }
}
