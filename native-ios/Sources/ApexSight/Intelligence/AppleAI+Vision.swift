import Foundation
import CoreGraphics
#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(Vision)
import Vision
#endif
// The OCR/barcode tools live in the Vision↔FoundationModels cross-import overlay; import it
// explicitly since the implicit overlay load doesn't always surface its symbols under the beta SDK.
#if canImport(_Vision_FoundationModels)
import _Vision_FoundationModels
#endif

/// iOS 27 **image-input** Foundation Models — the capability the original `AppleAI` explicitly
/// deferred ("Image input … iOS 27 and need the newer SDK"). Everything runs entirely on-device:
/// no frame ever leaves the phone. Gated three ways like the rest of `AppleAI` — SDK presence
/// (`canImport`), `@available(iOS 27)`, and the runtime `isAvailable` (Apple-Intelligence hardware
/// + model downloaded + user toggle). On anything that can't run it, every entry point returns nil
/// and the caller falls back silently.
///
/// NOTE: Apple Intelligence does not run on the iOS Simulator and needs iPhone 15 Pro / 16+
/// hardware, so this path is **compile-verified only** here — it must be exercised on a real
/// iOS 27 device.
@available(iOS 27.0, *)
extension AppleAI {

    /// True when on-device vision AI can actually run right now (mirrors `isAvailable`, which
    /// already checks model availability + the user master toggle).
    static var visionAIAvailable: Bool {
        #if canImport(FoundationModels)
        return isAvailable
        #else
        return false
        #endif
    }

    #if canImport(FoundationModels)

    /// Describe what's visible in a single camera frame, on-device. Powers a "What's in this
    /// frame? / Who's that?" affordance on the full-screen viewer and event detail.
    /// Returns nil on any failure so the caller falls back silently.
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

    #if canImport(_Vision_FoundationModels)
    /// Read clearly legible text in a frame (license plates, package labels, signage) using the
    /// on-device OCR tool. Returns nil when nothing is legible or AI is unavailable.
    static func readText(in image: CGImage) async -> String? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let session = LanguageModelSession(tools: [OCRTool()], instructions: """
        Extract any clearly legible text from the image — license plates, package labels, signage. \
        Reply with just the text you can read. If there is none, reply exactly "No legible text".
        """)
        let response = try? await session.respond(options: GenerationOptions()) {
            "What text is visible in this image?"
            Attachment(image)
        }
        let text = response?.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty,
              text.caseInsensitiveCompare("No legible text") != ComparisonResult.orderedSame else {
            return nil
        }
        return text
    }
    #endif

    #endif
}
