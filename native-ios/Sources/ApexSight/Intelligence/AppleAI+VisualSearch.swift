import Foundation
import CoreGraphics
#if canImport(Vision)
import Vision
#endif

/// Maps a captured frame (from the system Visual Intelligence camera) to the Frigate object
/// taxonomy so it can drive an event search. Vision does the *seeing* (same detectors the event
/// analysis uses); a small lexical map turns Vision/Visual-Intelligence terms into the labels
/// Frigate actually records (`person`, `car`, `dog`, `package`, …).
///
/// Pure/deterministic apart from the Vision pass, so the mapping is unit-verifiable off-device
/// (Vision also runs on macOS — see `scratchpad/` verification script).
extension AppleAI {

    /// What a captured frame resolves to, in Frigate's vocabulary.
    struct VisualSearchTerms: Equatable {
        /// Frigate object labels, most-confident first (e.g. `["car", "person"]`).
        var labels: [String]
        /// A license/number plate read from the frame, if any (for `recognized_license_plate`).
        var plate: String?
        /// Free-text scene terms for a semantic-search fallback (e.g. `"driveway, tree, daytime"`).
        var sceneQuery: String?

        var isEmpty: Bool { labels.isEmpty && plate == nil && (sceneQuery?.isEmpty ?? true) }
    }

    /// Frigate's common object labels (COCO-derived) that we can meaningfully search on.
    private static let frigateObjects: Set<String> = [
        "person", "car", "truck", "bus", "motorcycle", "bicycle",
        "dog", "cat", "bird", "horse", "package"
    ]

    /// Lexical map: a Vision/Visual-Intelligence term (lowercased, substring-matched) → Frigate label.
    /// Ordered by specificity so "fire truck" hits `truck` before "car".
    private static let termToFrigate: [(needle: String, label: String)] = [
        ("pickup", "truck"), ("truck", "truck"), ("lorry", "truck"),
        ("bus", "bus"),
        ("motorcycle", "motorcycle"), ("motorbike", "motorcycle"), ("scooter", "motorcycle"),
        ("bicycle", "bicycle"), ("bike", "bicycle"),
        ("sports car", "car"), ("race car", "car"), ("convertible", "car"),
        ("minivan", "car"), ("van", "car"), ("suv", "car"), ("taxi", "car"),
        ("automobile", "car"), ("vehicle", "car"), ("car", "car"),
        ("puppy", "dog"), ("dog", "dog"), ("canine", "dog"),
        ("kitten", "cat"), ("cat", "cat"), ("feline", "cat"),
        ("bird", "bird"),
        ("horse", "horse"),
        ("parcel", "package"), ("package", "package"), ("cardboard box", "package"),
        ("carton", "package"), ("box", "package"),
        ("person", "person"), ("people", "person"), ("man", "person"),
        ("woman", "person"), ("pedestrian", "person")
    ]

    /// Map one free-form term to a Frigate label, if it names something Frigate tracks.
    private static func frigateLabel(for term: String) -> String? {
        let t = term.lowercased()
        for (needle, label) in termToFrigate where t.contains(needle) { return label }
        return nil
    }

    /// Resolve a captured frame + any labels the system already supplied into Frigate search terms.
    /// - Parameters:
    ///   - image: the captured frame (from `SemanticContentDescriptor.pixelBuffer`), or nil.
    ///   - systemLabels: `SemanticContentDescriptor.labels` — high-level en_US scene terms.
    static func visualSearchTerms(image: CGImage?, systemLabels: [String]) async -> VisualSearchTerms {
        var labelHits: [String] = []          // preserves confidence order, de-duped below
        var sceneTerms: [String] = []
        var plate: String?

        // 1. Terms Visual Intelligence already classified (cheap, always present).
        for term in systemLabels {
            if let label = frigateLabel(for: term) { labelHits.append(label) }
            else { sceneTerms.append(term) }
        }

        // 2. Our own Vision pass on the pixels — catches objects VI's scene labels miss, and
        //    counts people/pets the way the rest of the app does.
        if let image {
            let vision = await visionSearchObservations(in: image)
            labelHits.append(contentsOf: vision.labels)
            sceneTerms.append(contentsOf: vision.scenes)
            plate = vision.plate
        }

        // De-dupe labels while keeping first-seen (most-confident) order.
        var seen = Set<String>()
        let labels = labelHits.filter { frigateObjects.contains($0) && seen.insert($0).inserted }

        // A compact scene query for the semantic-search bonus path (de-duped, trimmed).
        var seenScene = Set<String>()
        let scene = sceneTerms
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seenScene.insert($0).inserted }
            .prefix(5)
            .joined(separator: ", ")

        return VisualSearchTerms(labels: labels, plate: plate, sceneQuery: scene.isEmpty ? nil : scene)
    }

    /// Vision detectors mapped to Frigate labels + scene terms + any plate text. Mirrors the event
    /// analysis path (`VNDetectHumanRectanglesRequest` / `VNRecognizeAnimalsRequest` /
    /// `VNClassifyImageRequest`) so behavior is consistent with the rest of the AI.
    private static func visionSearchObservations(
        in image: CGImage
    ) async -> (labels: [String], scenes: [String], plate: String?) {
        #if canImport(Vision)
        let plate = await readText(in: image).flatMap(licensePlate(in:))
        return await withCheckedContinuation { continuation in
            var labels: [String] = []
            var scenes: [String] = []

            let humans = VNDetectHumanRectanglesRequest()
            let animals = VNRecognizeAnimalsRequest()
            let classify = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([humans, animals, classify])

            if let people = humans.results, !people.isEmpty { labels.append("person") }
            if let pets = animals.results {
                for id in pets.compactMap({ $0.labels.first?.identifier }) {
                    if let label = frigateLabel(for: id) { labels.append(label) }
                }
            }
            if let results = classify.results {
                let confident = results.filter { $0.confidence > 0.5 }
                // Scan ALL confident classifications for object terms — scene descriptors
                // (land/grass/outdoor) outrank objects in a camera frame, so a top-N slice
                // silently drops the car/person we're trying to match (verified on real
                // Frigate snapshots: a clear car ranks `automobile`/`vehicle` only 7th–8th).
                for r in confident {
                    let term = r.identifier.replacingOccurrences(of: "_", with: " ")
                    if let label = frigateLabel(for: term) { labels.append(label) }
                }
                // Scene terms for the semantic-search fallback: top few non-object descriptors.
                for r in confident.prefix(6) {
                    let term = r.identifier.replacingOccurrences(of: "_", with: " ")
                    if frigateLabel(for: term) == nil { scenes.append(term) }
                }
            }
            continuation.resume(returning: (labels, scenes, plate))
        }
        #else
        return ([], [], nil)
        #endif
    }

    /// Heuristic: is a run of recognized text plausibly a license/number plate? (5–8 chars,
    /// letters+digits, no spaces.) Keeps random signage out of the plate field.
    private static func licensePlate(in text: String) -> String? {
        let candidates = text
            .split(whereSeparator: { $0 == "\n" || $0 == " " })
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased() }
        return candidates.first { c in
            (5...8).contains(c.count)
                && c.range(of: "[A-Z]", options: .regularExpression) != nil
                && c.range(of: "[0-9]", options: .regularExpression) != nil
                && c.allSatisfy { $0.isLetter || $0.isNumber }
        }
    }
}
