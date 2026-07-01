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

        // Deliberately LIGHT for the notification extension: people count + pets + text only. These
        // are fast (no heavy image-classifier model to load, which was delaying the alert), and they
        // add exactly what Frigate's own label ("Person"/"Package") doesn't — how many, pets, plates.
        let humans = VNDetectHumanRectanglesRequest()
        let animals = VNRecognizeAnimalsRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([humans, animals, text])

        if let people = humans.results, !people.isEmpty {
            facts.append(people.count == 1 ? "1 person" : "\(people.count) people")
        }
        if let pets = animals.results {
            for label in Set(pets.compactMap { $0.labels.first?.identifier }).sorted() {
                facts.append("a \(label)")
            }
        }

        var summary: String? = facts.isEmpty ? nil : facts.joined(separator: ", ")

        // Append a legible plate/label — but Frigate BURNS a timestamp + "person: 88%" overlay into
        // snapshots, so filter that out or OCR "reads" the clock. Only real text survives.
        if let obs = text.results {
            let read = obs.compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces) }
                .filter { isRealText($0) }
            if let first = read.first {
                summary = (summary.map { $0 + " · " } ?? "") + "“\(first)”"
            }
        }

        return (summary?.isEmpty == false) ? summary : nil
    }

    /// Reject Frigate's burned-in overlay so OCR doesn't surface the clock/label as "text":
    /// dates (06/30/2026), times (17:39:50), detector scores ("person: 88%"), and junk.
    public static func isRealText(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3 else { return false }
        let lower = t.lowercased()
        // date / time / score overlays
        if t.range(of: #"^\d{1,2}[/:.\-]\d{1,2}([/:.\-]\d{2,4})?$"#, options: .regularExpression) != nil { return false }
        if t.range(of: #"^\d{1,2}:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil { return false }
        if lower.range(of: #"^(person|car|truck|dog|cat|bird|package|bicycle|motorcycle|bus|face)\s*:?\s*\d"#, options: .regularExpression) != nil { return false }
        // must contain at least a couple of letters/digits and not be mostly punctuation
        let alnum = t.filter { $0.isLetter || $0.isNumber }
        return alnum.count >= 3
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
