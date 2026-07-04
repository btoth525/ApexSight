import Foundation
import Photos
import SwiftUI

/// Drives Frigate's server-side export: kick off one or more render jobs, poll until they're
/// ready, download the finished MP4s, and hand them to the share sheet / Photos. All the heavy
/// video work happens on the Frigate host (ffmpeg), so this is robust for every camera — including
/// the ultra-wide HEVC ones the phone can't re-encode.
@MainActor
final class ExportManager: ObservableObject {
    enum Phase: Equatable {
        case idle
        case rendering(done: Int, total: Int)
        case downloading
        case finished([URL])
        case failed(String)
    }

    struct Window: Identifiable, Hashable {
        let camera: String
        let start: Double
        let end: Double
        var id: String { "\(camera)-\(Int(start))-\(Int(end))" }
    }

    @Published var phase: Phase = .idle

    var isBusy: Bool {
        switch phase {
        case .rendering, .downloading: return true
        default: return false
        }
    }

    /// Render + download the given windows. Returns the local file URLs (also published via `phase`).
    @discardableResult
    func export(windows: [Window], name: String?, client: FrigateClient) async -> [URL] {
        guard !windows.isEmpty else { return [] }
        phase = .rendering(done: 0, total: windows.count)

        // Kick off every render job.
        var ids: [String] = []
        do {
            for w in windows {
                let id = try await client.startExport(camera: w.camera, start: w.start, end: w.end, name: name)
                ids.append(id)
            }
        } catch {
            phase = .failed(Self.message(error)); return []
        }

        // Poll until each id reports ready (Frigate renders in seconds, but a long window or a
        // busy host can take longer — cap at ~2 minutes).
        var ready: [FrigateExport] = []
        let deadline = 80   // ~80 * 1.5s ≈ 2 min
        for _ in 0..<deadline {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let current = (try? await client.exports()) ?? []
            ready = current.filter { ids.contains($0.id) && $0.isReady }
            phase = .rendering(done: ready.count, total: ids.count)
            if ready.count == ids.count { break }
        }
        guard !ready.isEmpty else {
            phase = .failed("Frigate is still rendering — check My Exports in a moment."); return []
        }

        // Download each finished file to a temp location for sharing/saving.
        phase = .downloading
        var urls: [URL] = []
        for export in ready {
            guard let filename = export.filename else { continue }
            let remote = client.exportFileURL(filename: filename)
            if let local = try? await client.downloadClipFile(from: remote, suggestedName: filename) {
                urls.append(local)
            }
        }
        guard !urls.isEmpty else {
            phase = .failed("Rendered, but the download failed. It's saved in My Exports."); return []
        }
        phase = .finished(urls)
        return urls
    }

    /// Convenience for a single event (used by event/review detail).
    @discardableResult
    func exportEvent(_ event: FrigateEvent, pad: TimeInterval = 3, name: String?, client: FrigateClient) async -> [URL] {
        guard let start = event.startTime else { phase = .failed("This event has no time range."); return [] }
        let end = event.endTime ?? (start + 10)
        return await export(windows: [Window(camera: event.camera, start: start - pad, end: end + pad)],
                            name: name, client: client)
    }

    func reset() { phase = .idle }

    /// Save downloaded files to the photo library (best-effort; reports the outcome via `phase`).
    func saveToPhotos(_ urls: [URL]) async {
        guard await requestAdd() else { phase = .failed("Photos access denied."); return }
        do {
            for url in urls {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
            }
            phase = .finished(urls)
        } catch {
            phase = .failed("Couldn't save to Photos.")
        }
    }

    private func requestAdd() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .authorized || status == .limited { return true }
        if status == .notDetermined {
            return await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized
        }
        return false
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Export failed."
    }
}
