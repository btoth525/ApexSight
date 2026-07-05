import AVFoundation
import Foundation

/// Builds a short, stitched **highlight reel** on-device: takes the first few seconds of each
/// detection, downscales to 1080p H.264, and concatenates them into ONE small file. 1080p H.264
/// is the sweet spot — small, plays anywhere, and (unlike the ultra-wide source) Photos accepts it.
///
/// Each segment is transcoded independently and SKIPPED on failure, so a source the device can't
/// decode (e.g. the 4096-wide camera on a device without the decode headroom) drops out instead of
/// sinking the whole reel. Video-only by design.
enum HighlightReelBuilder {
    static let renderSize = CGSize(width: 1920, height: 1080)

    /// Downscale the first `seconds` of a local clip to a 1080p H.264 file. Returns nil if the
    /// device can't decode/encode this source (e.g. the ultra-wide HEVC on a limited decoder).
    static func transcodeFirst(_ url: URL, seconds: Double) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let duration = try? await asset.load(.duration) else { return nil }
        let composition = AVMutableComposition()
        guard let compTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        let take = min(CMTime(seconds: seconds, preferredTimescale: 600), duration)
        guard take.seconds > 0.1 else { return nil }
        do { try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: take), of: track, at: .zero) }
        catch { return nil }

        let natural = (try? await track.load(.naturalSize)) ?? renderSize
        let preferred = (try? await track.load(.preferredTransform)) ?? .identity
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrack)
        layer.setTransform(aspectFit(source: natural, preferred: preferred, into: renderSize), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: take)
        instruction.layerInstructions = [layer]
        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize = renderSize
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)
        videoComp.instructions = [instruction]

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1920x1080) else { return nil }
        let out = tempURL()
        export.outputURL = out
        export.outputFileType = .mp4
        export.videoComposition = videoComp
        await export.export()
        return export.status == .completed ? out : nil
    }

    /// Concatenate uniform 1080p segments into one file. (All segments are already 1080p, so a
    /// single composition track needs no per-segment transform.)
    static func concat(_ segments: [URL], name: String) async -> URL? {
        guard !segments.isEmpty else { return nil }
        let composition = AVMutableComposition()
        guard let compTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        var cursor = CMTime.zero
        for seg in segments {
            let asset = AVURLAsset(url: seg)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration) else { continue }
            try? compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: cursor)
            cursor = cursor + duration
        }
        guard cursor.seconds > 0 else { return nil }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { return nil }
        let out = namedTempURL(name)
        export.outputURL = out
        export.outputFileType = .mp4
        await export.export()
        // Clean up the intermediate segments regardless of outcome.
        segments.forEach { try? FileManager.default.removeItem(at: $0) }
        return export.status == .completed ? out : nil
    }

    /// Evenly sample up to `max` items across the list (not just the first N) so a long incident's
    /// reel spans the whole thing instead of the first minute.
    static func sampleEvenly<T>(_ items: [T], max: Int) -> [T] {
        guard items.count > max, max > 0 else { return items }
        let step = Double(items.count) / Double(max)
        return (0..<max).map { items[min(items.count - 1, Int(Double($0) * step))] }
    }

    // MARK: - Helpers

    private static func aspectFit(source: CGSize, preferred: CGAffineTransform, into render: CGSize) -> CGAffineTransform {
        let displayed = CGRect(origin: .zero, size: source).applying(preferred).size
        let w = abs(displayed.width), h = abs(displayed.height)
        guard w > 0, h > 0 else { return preferred }
        let scale = min(render.width / w, render.height / h)
        return preferred
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (render.width - w * scale) / 2,
                                             y: (render.height - h * scale) / 2))
    }

    private static func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("seg-\(UUID().uuidString).mp4")
    }

    private static func namedTempURL(_ name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reel-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(safe.isEmpty ? "Highlight" : safe).appendingPathExtension("mp4")
    }
}
