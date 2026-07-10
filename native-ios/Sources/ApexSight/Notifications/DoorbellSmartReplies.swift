import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Suggests short things to say to a doorbell visitor. Uses Apple's on-device model (iOS 26+ Apple
/// Intelligence, `FoundationModels`) when it's available on the device; otherwise returns curated
/// static presets. Always safe to call — the soundboard never depends on the model being present.
enum DoorbellSmartReplies {
    static let presets = [
        "Be right there!",
        "Leave it at the door, please.",
        "Thanks, just leave the package.",
        "One moment, please.",
        "Sorry, we can't come right now.",
        "Who is it?",
    ]

    /// True when the on-device language model is ready (Apple Intelligence enabled + model present).
    static var modelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Return short reply suggestions. Uses the on-device model when available (falls back to
    /// `presets` on any error or when unavailable).
    static func suggestions(context: String = "") async -> [String] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), SystemLanguageModel.default.isAvailable {
            let prompt = """
            Suggest 5 very short, friendly things a homeowner might say to a visitor at their front \
            door through a doorbell speaker. Each reply must be under 8 words. \(context)
            List each reply on its own line with no numbering or quotes.
            """
            do {
                let session = LanguageModelSession()
                let reply = try await session.respond(to: prompt)
                let lines = reply.content
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t-•*\"'")) }
                    .filter { !$0.isEmpty && $0.count <= 60 }
                if !lines.isEmpty { return Array(lines.prefix(6)) }
            } catch {
                // fall through to presets
            }
        }
        #endif
        return presets
    }
}
