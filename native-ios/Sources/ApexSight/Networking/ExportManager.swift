import Foundation
import Photos
import SwiftUI

/// A URLSession download that reports byte-level progress, bridged to async/await. Used for the
/// live "downloading…" bar when pulling a finished Frigate export.
final class ProgressDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    private init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    static func run(request: URLRequest, onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await ProgressDownloader(onProgress: onProgress).start(request: request)
    }

    private func start(request: URLRequest) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        defer { session.finishTasksAndInvalidate() }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: FrigateError.badResponse(http.statusCode)); continuation = nil; return
        }
        // The delegate temp file is deleted once this returns — move it somewhere stable first.
        let stable = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString).mp4")
        do { try FileManager.default.moveItem(at: location, to: stable); continuation?.resume(returning: stable) }
        catch { continuation?.resume(throwing: error) }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        if let error, continuation != nil { continuation?.resume(throwing: error); continuation = nil }
    }
}

/// Drives Frigate's server-side export: kick off one or more render jobs, poll until they're
/// ready, download the finished MP4s, and hand them to the share sheet / Photos. All the heavy
/// video work happens on the Frigate host (ffmpeg), so this is robust for every camera — including
/// the ultra-wide HEVC ones the phone can't re-encode.
@MainActor
final class ExportManager: ObservableObject {
    enum Phase: Equatable {
        case idle
        case rendering(done: Int, total: Int)
        case downloading(progress: Double)   // 0…1 overall across all files
        case saving
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
        case .rendering, .downloading, .saving: return true
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

        // Download each finished file, reporting live byte-level progress (overall across files).
        phase = .downloading(progress: 0)
        let total = ready.count
        var urls: [URL] = []
        for (i, export) in ready.enumerated() {
            guard let filename = export.filename else { continue }
            let remote = client.exportFileURL(filename: filename)
            let base = Double(i)
            let local = try? await client.downloadClipFile(from: remote, suggestedName: filename) { [weak self] frac in
                Task { @MainActor in
                    guard let self, case .downloading = self.phase else { return }
                    self.phase = .downloading(progress: (base + frac) / Double(total))
                }
            }
            if let local { urls.append(local) }
        }
        guard !urls.isEmpty else {
            phase = .failed("Rendered, but the download failed. It's in My Exports."); return []
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

    /// Save downloaded files to the photo library. Each clip is saved INDEPENDENTLY so one bad
    /// clip (e.g. a codec Photos rejects) doesn't sink the rest, and the real underlying error is
    /// surfaced instead of a generic message.
    func saveToPhotos(_ urls: [URL]) async {
        guard await requestAdd() else {
            phase = .failed("Photos access is off — enable it in Settings › ApexSight › Photos."); return
        }
        phase = .saving
        var saved = 0
        var lastError: String?
        for url in urls {
            // Skip anything that didn't actually land on disk.
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? Int) ?? 0
            guard size > 0 else { lastError = "The clip file was empty."; continue }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    // PHAssetCreationRequest.addResource is more robust than
                    // creationRequestForAssetFromVideo and gives a real error on rejection.
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = false
                    request.addResource(with: .video, fileURL: url, options: options)
                }
                saved += 1
            } catch {
                lastError = (error as NSError).localizedDescription
            }
        }
        if saved == urls.count {
            phase = .finished(urls)
        } else if saved > 0 {
            phase = .failed("Saved \(saved) of \(urls.count). \(lastError ?? "")")
        } else {
            phase = .failed(lastError ?? "Couldn't save to Photos.")
        }
    }

    private func requestAdd() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .authorized || status == .limited { return true }
        if status == .notDetermined {
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return granted == .authorized || granted == .limited
        }
        return false
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Export failed."
    }
}
