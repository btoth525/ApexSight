import Foundation
import CoreGraphics
import ImageIO
#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(Vision)
import Vision
#endif

/// On-device image understanding for camera frames — Vision does the *seeing*, Foundation Models
/// (optionally) does the *phrasing*. This split is deliberate: the on-device `SystemLanguageModel`
/// is TEXT-ONLY (its only use cases are `.general` / `.contentTagging` — no image input, verified
/// against the iOS 27 SDK interface), so an image handed straight to the LLM is ignored. Vision's
/// classifiers/detectors are mature, run on ANY device, and actually look at pixels.
///
/// Everything runs entirely on-device; no frame ever leaves the phone.
extension AppleAI {

    /// True when on-device scene analysis can run — Vision is always available on iOS 17+, so this
    /// is effectively the user's AI master toggle. (Foundation Models phrasing is a bonus on top.)
    static var visionAIAvailable: Bool { userEnabled }

    /// Describe who/what is visible in a camera frame, fully on-device. Vision classifies the scene
    /// and counts people/pets; the on-device text model (when available) turns those facts into a
    /// natural sentence. Returns nil only if Vision finds nothing legible.
    static func describeScene(in image: CGImage, cameraName: String, knownLabel: String? = nil) async -> String? {
        var facts = await visionObservations(in: image)
        // Frigate's own detection is authoritative (Vision's person detector misses partial/indoor
        // people), so seed it if Vision didn't independently surface it.
        if let knownLabel, !knownLabel.isEmpty,
           !facts.contains(where: { $0.localizedCaseInsensitiveContains(knownLabel) }) {
            facts.insert("a \(knownLabel)", at: 0)
        }
        guard !facts.isEmpty else { return nil }
        let factual = facts.joined(separator: ", ")

        #if canImport(FoundationModels)
        if #available(iOS 26, *), SystemLanguageModel.default.isAvailable {
            let session = LanguageModelSession(instructions: """
            You write one concise, natural sentence for a home-security app describing what a camera \
            sees, based only on the supplied observations. Do not invent anything not listed. No \
            preamble — just the sentence.
            """)
            if let response = try? await session.respond(to: "Camera \"\(cameraName)\" observations: \(factual)") {
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        #endif
        // Fallback (no Apple-Intelligence model): present Vision's facts directly.
        return factual.prefix(1).uppercased() + factual.dropFirst() + "."
    }

    /// Run Vision on-device: people count, recognized animals, and top scene/object classifications.
    /// Returns short human-readable fact phrases (e.g. ["2 people", "a dog", "driveway", "outdoor"]).
    private static func visionObservations(in image: CGImage) async -> [String] {
        #if canImport(Vision)
        return await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
            var facts: [String] = []

            let humans = VNDetectHumanRectanglesRequest()
            let animals = VNRecognizeAnimalsRequest()
            let classify = VNClassifyImageRequest()

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([humans, animals, classify])

            if let people = humans.results, !people.isEmpty {
                facts.append(people.count == 1 ? "1 person" : "\(people.count) people")
            }
            if let pets = animals.results {
                let labels = Set(pets.compactMap { $0.labels.first?.identifier })
                for label in labels.sorted() { facts.append("a \(label)") }
            }
            if let scenes = classify.results {
                let top = scenes
                    .filter { $0.confidence > 0.4 && $0.hasMinimumPrecision(0.5, forRecall: 0.5) }
                    .prefix(3)
                    .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
                facts.append(contentsOf: top)
            }
            continuation.resume(returning: facts)
        }
        #else
        return []
        #endif
    }

    /// Analyze a short event as a SEQUENCE of frames (from its preview GIF) so the AI understands
    /// motion/activity — "a person walked up, left a package, and left" — not just one still frame.
    /// Vision reads each frame; the on-device language model narrates the sequence. Returns nil if
    /// the GIF has too few frames or nothing was observed (caller falls back to single-frame).
    static func describeEvent(gifData: Data, cameraName: String, knownLabel: String? = nil) async -> String? {
        let frames = extractFrames(from: gifData, maxFrames: 6)
        guard frames.count >= 2 else { return nil }

        var timeline: [String] = []
        for (i, frame) in frames.enumerated() {
            let facts = await visionObservations(in: frame)
            if !facts.isEmpty { timeline.append("Moment \(i + 1): \(facts.joined(separator: ", "))") }
        }
        // Anchor on Frigate's authoritative detection so the narration names the object even when
        // Vision's frame-by-frame detectors miss a partial/indoor subject.
        if let knownLabel, !knownLabel.isEmpty {
            timeline.insert("The camera detected a \(knownLabel).", at: 0)
        }
        guard !timeline.isEmpty else { return nil }

        // OCR across frames from the end (subjects are usually closest/clearest by the last frames).
        var legibleText: String?
        for frame in frames.reversed() {
            if let t = await readText(in: frame) { legibleText = t; break }
        }

        let observations = timeline.joined(separator: "\n")

        #if canImport(FoundationModels)
        if #available(iOS 26, *), SystemLanguageModel.default.isAvailable {
            let session = LanguageModelSession(instructions: eventNarrationInstructions(cameraName: cameraName))
            var prompt = "Time-ordered observations from the clip:\n\(observations)"
            if let legibleText { prompt += "\nText or license plate read in the clip: \(legibleText)" }
            if let response = try? await session.respond(to: prompt) {
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        #endif

        // Factual fallback with no on-device language model.
        var summary = timeline.joined(separator: "; ")
        if let legibleText { summary += "\n\n📄 Text seen: \(legibleText)" }
        return summary
    }

    /// The temporal-narration prompt — deliberately strong: chronological, movement-focused, no
    /// hallucination, security-log tone, plate verbatim.
    private static func eventNarrationInstructions(cameraName: String) -> String {
        """
        You are a home-security analyst writing a short, factual log entry for a camera named \
        "\(cameraName)". You are given time-ordered observations of a brief event clip — each line is \
        what an on-device vision model detected at one moment, in chronological order. Write 1–2 \
        concise, natural sentences describing what HAPPENED across the clip: who or what appeared, what \
        they did, and how the scene changed over time (arrived, approached, left something, walked \
        past, drove by, lingered, departed). Emphasize movement and the change between moments rather \
        than listing each moment. If a license plate or text was read, include it verbatim. Never \
        invent anything that is not in the observations. No preamble and never say "frame", "moment", \
        or "the clip shows" — just the log entry itself, e.g.: "A delivery driver walked up to the \
        porch, set down a package, and returned to a white van."
        """
    }

    /// Sample up to `maxFrames` evenly-spaced frames from animated image data (a Frigate preview GIF).
    private static func extractFrames(from data: Data, maxFrames: Int) -> [CGImage] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return [] }
        let n = min(maxFrames, count)
        var frames: [CGImage] = []
        for i in 0..<n {
            let index = n == 1 ? 0 : Int((Double(i) * Double(count - 1) / Double(n - 1)).rounded())
            if let cg = CGImageSourceCreateImageAtIndex(source, index, nil) { frames.append(cg) }
        }
        return frames
    }

    /// Read clearly legible text in a frame (license plates, package labels, signage) via Vision's
    /// on-device text recognizer. Runs on any iOS 17+ device. Returns nil when nothing is legible.
    static func readText(in image: CGImage) async -> String? {
        #if canImport(Vision)
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: nil); return
                }
                let lines = observations
                    .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
                    // Drop Frigate's burned-in timestamp / "person: 88%" overlay so OCR returns
                    // only real text (plates, package labels), not the clock.
                    .filter { SceneVision.isRealText($0) }
                continuation.resume(returning: lines.isEmpty ? nil : lines.joined(separator: " · "))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false  // plates/labels aren't dictionary words
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do { try handler.perform([request]) } catch { continuation.resume(returning: nil) }
        }
        #else
        return nil
        #endif
    }
}
