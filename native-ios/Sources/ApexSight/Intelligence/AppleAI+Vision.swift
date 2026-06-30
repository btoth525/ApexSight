import Foundation
import CoreGraphics
#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(Vision)
import Vision
#endif

/// On-device image understanding for camera frames. Two independent capabilities:
///
/// 1. `describeScene` — iOS 27 multimodal Foundation Models ("who/what is in this frame"). Needs
///    Apple-Intelligence hardware + iOS 27; gated and compile-guarded, returns nil otherwise.
/// 2. `readText` — license-plate / label / signage OCR via **Vision** (`VNRecognizeTextRequest`,
///    iOS 13+). Mature, fast, runs on ANY device — deliberately NOT tied to Apple Intelligence,
///    so plate reading works even where the LLM can't run.
///
/// Everything runs entirely on-device; no frame leaves the phone. NOTE: the Foundation Models
/// path does not run on the simulator — verify `describeScene` on a real iOS 27 device.
@available(iOS 27.0, *)
extension AppleAI {

    /// True when on-device scene description (Foundation Models image input) can run right now.
    static var visionAIAvailable: Bool {
        #if canImport(FoundationModels)
        return isAvailable
        #else
        return false
        #endif
    }

    #if canImport(FoundationModels)
    /// Describe what's visible in a single camera frame, on-device. Returns nil on any failure.
    static func describeScene(in image: CGImage, cameraName: String) async -> String? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
        You analyze a still frame from a home-security camera named "\(cameraName)". Describe \
        concisely what is visible — people, vehicles, packages, animals, notable activity. Two \
        sentences maximum. Never invent details you cannot actually see in the frame.
        """)
        let response = try? await session.respond(options: GenerationOptions()) {
            "Describe this camera frame."
            Attachment(image)
        }
        let text = response?.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }
    #endif
}

extension AppleAI {
    /// Read clearly legible text in a frame (license plates, package labels, signage) using
    /// Vision's on-device text recognizer. Runs on any iOS 17+ device — no Apple Intelligence
    /// required. Returns nil when nothing legible is found.
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
            // Plates / labels aren't dictionary words — language correction hurts more than helps.
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
        #else
        return nil
        #endif
    }
}
