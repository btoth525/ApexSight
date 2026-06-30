import Foundation
import CoreGraphics
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
    static func describeScene(in image: CGImage, cameraName: String) async -> String? {
        let facts = await visionObservations(in: image)
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
                    .filter { $0.count >= 2 }
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
