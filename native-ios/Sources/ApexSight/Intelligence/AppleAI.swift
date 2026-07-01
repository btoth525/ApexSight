import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device Apple Intelligence (Foundation Models) helpers — **text only**. Image input,
/// OCR/barcode tools, and Private Cloud Compute are iOS 27 and need the newer SDK, so they're
/// deliberately out of scope here. Everything runs entirely on the device (no network, no cloud,
/// no footage leaves the phone) and is gated: the `canImport`/`@available(iOS 26)` SDK gates, the
/// runtime `isAvailable` capability gate (Apple-Intelligence hardware + model downloaded), and a
/// user setting. The whole type compiles even on toolchains without FoundationModels (CI / older
/// Xcode) — AI is simply reported unavailable and every caller falls back to existing behaviour.
enum AppleAI {
    /// User master switch (Settings → "Apple Intelligence"). Default on; flipping it off hides
    /// every AI affordance regardless of hardware.
    static var userEnabled: Bool {
        // App Group so the Notification Service Extension can honor the master toggle too.
        let defaults = UserDefaults(suiteName: ApexAppGroup.identifier) ?? .standard
        return defaults.object(forKey: "appleIntelligenceEnabled") as? Bool ?? true
    }

    /// Whether this device can run the on-device model at all (SDK present, iOS 26+, Apple-
    /// Intelligence hardware, model downloaded) — ignoring the user toggle. Drives whether the
    /// Settings toggle is even shown, so devices that can't do AI never see a dead switch.
    static var deviceSupportsAI: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// True only when the on-device text model can actually run right now AND the user hasn't
    /// disabled it. Drives whether AI affordances are shown at all.
    static var isAvailable: Bool {
        userEnabled && deviceSupportsAI
    }

    #if canImport(FoundationModels)

    /// A short on-device summary for a prompt (used by the daily digest and search answers).
    /// Returns nil on any failure so the caller can fall back to its existing text.
    @available(iOS 26, *)
    static func summarize(instructions: String, prompt: String) async -> String? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        guard let response = try? await session.respond(to: prompt) else { return nil }
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Natural-language search → structured Frigate filters

    /// The structured filter the model extracts from a free-text request. Mapped to
    /// `FrigateClient.events(...)` params by the caller.
    @available(iOS 26, *)
    @Generable
    struct FrigateQuery {
        @Guide(description: "Exact camera name the request is about, or nil for all cameras")
        var camera: String?
        @Guide(description: "Object label such as person, car, truck, dog, cat, package; nil for any")
        var label: String?
        @Guide(description: "Zone name the request mentions, or nil")
        var zone: String?
        @Guide(description: "True only if the request asks for events that have a recorded video clip")
        var hasClip: Bool
    }

    /// Parse a natural-language request into structured filters, constrained to the server's
    /// real camera/label names. Returns nil if AI is unavailable or parsing fails.
    @available(iOS 26, *)
    static func parseQuery(_ text: String, cameras: [String], labels: [String]) async -> FrigateQuery? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
        Convert a natural-language request about home-security footage into structured filters. \
        Available cameras: \(cameras.joined(separator: ", ")). \
        Common labels: \(labels.joined(separator: ", ")). \
        Only set camera/label/zone when the request clearly implies one; otherwise leave it nil. \
        Match camera and label values to the available names exactly.
        """)
        guard let response = try? await session.respond(to: text, generating: FrigateQuery.self) else { return nil }
        return response.content
    }

    #endif
}
