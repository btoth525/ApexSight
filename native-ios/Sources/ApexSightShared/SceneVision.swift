import Foundation
import ImageIO
import CoreGraphics
#if canImport(Vision)
import Vision
#endif

/// Fast, concise on-device scene summary from an image — used to enrich push notifications in the
/// Notification Service Extension (so an alert reads "👁️ 2 people, a package" instead of just
/// "Motion"). Vision only, no language model (too heavy/unavailable in an extension). Downsamples
/// first to stay well under the NSE memory budget. Returns nil on watchOS or when nothing is found.
public enum SceneVision {

    /// Summarize the first frame of image (or GIF) data. Safe for the tight NSE memory limit.
    public static func summarize(imageData: Data) -> String? {
        #if canImport(Vision)
        guard let cg = downsampledCGImage(imageData, maxPixel: 1024) else { return nil }
        return summarize(cgImage: cg)
        #else
        return nil
        #endif
    }

    #if canImport(Vision)
    public static func summarize(cgImage: CGImage) -> String? {
        var facts: [String] = []

        let humans = VNDetectHumanRectanglesRequest()
        let animals = VNRecognizeAnimalsRequest()
        let classify = VNClassifyImageRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([humans, animals, classify, text])

        if let people = humans.results, !people.isEmpty {
            facts.append(people.count == 1 ? "1 person" : "\(people.count) people")
        }
        if let pets = animals.results {
            for label in Set(pets.compactMap { $0.labels.first?.identifier }).sorted() {
                facts.append("a \(label)")
            }
        }
        // Only fall back to scene classification when there were no people/animals — those are the
        // security-relevant subjects; scene labels ("driveway") are context.
        if facts.isEmpty, let scenes = classify.results {
            let top = scenes
                .filter { $0.confidence > 0.45 && $0.hasMinimumPrecision(0.5, forRecall: 0.4) }
                .prefix(2)
                .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
            facts.append(contentsOf: top)
        }

        var summary: String? = facts.isEmpty ? nil : facts.joined(separator: ", ")

        // Append a legible plate/label if the recognizer found one.
        if let obs = text.results {
            let read = obs.compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces) }
                .filter { $0.count >= 3 }
            if let first = read.first {
                summary = (summary.map { $0 + " · " } ?? "") + "“\(first)”"
            }
        }

        return (summary?.isEmpty == false) ? summary : nil
    }
    #endif

    /// ImageIO thumbnail — decodes at most `maxPixel` on the long edge, so a multi-MB snapshot never
    /// inflates to a full bitmap in the extension.
    private static func downsampledCGImage(_ data: Data, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
