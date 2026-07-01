import AppIntents
import Foundation
import CoreImage
import CoreVideo

// The VisualIntelligence framework ships only in the device SDK (not the simulator), so the whole
// query is gated on its availability — it can only run on a real Apple-Intelligence device anyway.
#if canImport(VisualIntelligence)
import VisualIntelligence

/// Visual Intelligence integration: the system captures a frame (its camera or a screenshot),
/// hands us a `SemanticContentDescriptor` (scene labels + a read-only pixel buffer), and we return
/// matching camera events. Discovered automatically by the App Intents runtime because its `Input`
/// is `SemanticContentDescriptor` — no explicit registration (per Apple's "Integrating your app
/// with Visual Intelligence").
///
/// Verified against the iOS 26 SDK interfaces (`IntentValueQuery`, `SemanticContentDescriptor`,
/// `CVReadOnlyPixelBuffer.withUnsafeBuffer`). The image→event matching logic is exercised
/// off-device in `scratchpad/`; the system-invocation path itself only runs on a real device.
@available(iOS 26.0, *)
struct EventVisualSearchQuery: IntentValueQuery {

    func values(for input: SemanticContentDescriptor) async throws -> [EventEntity] {
        let frame = input.pixelBuffer.flatMap(Self.cgImage(from:))
        let terms = await AppleAI.visualSearchTerms(image: frame, systemLabels: input.labels)
        guard !terms.isEmpty, let session = KeychainStore().loadSession() else { return [] }

        let client = FrigateClient(session: session)
        let lookback = Date().addingTimeInterval(-30 * 24 * 60 * 60)   // last 30 days
        var events: [FrigateEvent] = []
        var seen = Set<String>()

        // One query per derived object label, most-confident label first.
        for label in terms.labels.prefix(3) {
            let hits = (try? await client.events(
                label: label, after: lookback, limit: 8, hasSnapshot: true
            )) ?? []
            for e in hits where seen.insert(e.id).inserted { events.append(e) }
        }

        // Plate / scene bonus via semantic search (no-ops on a Frigate without embeddings).
        if let plate = terms.plate {
            for e in await client.safeSemanticSearch(query: plate, after: lookback, limit: 6)
            where seen.insert(e.id).inserted { events.append(e) }
        } else if events.isEmpty, let scene = terms.sceneQuery {
            for e in await client.safeSemanticSearch(query: scene, after: lookback, limit: 6)
            where seen.insert(e.id).inserted { events.append(e) }
        }

        // Newest first, capped — Visual Intelligence shows a compact result set.
        let top = events
            .sorted { ($0.startTime ?? 0) > ($1.startTime ?? 0) }
            .prefix(10)

        // Pre-fetch each thumbnail (Frigate needs auth) into a local file for the result image.
        return await withTaskGroup(of: EventEntity.self) { group in
            for event in top {
                group.addTask {
                    let path = await Self.cacheThumbnail(client: client, id: event.id)
                    return EventEntity(event: event, thumbnailPath: path)
                }
            }
            var out: [EventEntity] = []
            for await entity in group { out.append(entity) }
            // Restore newest-first order (task group completes out of order).
            return out.sorted { ($0.when ?? .distantPast) > ($1.when ?? .distantPast) }
        }
    }

    /// Convert the Visual Intelligence read-only pixel buffer to a CGImage. `CVReadOnlyPixelBuffer`
    /// only vends its backing `CVPixelBuffer` inside `withUnsafeBuffer`; the CGImage we render is a
    /// fresh copy, so it's safe to hand back out.
    private static func cgImage(from buffer: CVReadOnlyPixelBuffer) -> CGImage? {
        buffer.withUnsafeBuffer { (pixelBuffer: CVPixelBuffer) -> CGImage? in
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            return CIContext().createCGImage(ciImage, from: ciImage.extent)
        }
    }

    /// Fetch an event's cropped thumbnail (authenticated) to a temp file; returns its path or nil.
    private static func cacheThumbnail(client: FrigateClient, id: String) async -> String? {
        let request = client.authedRequest(for: client.eventThumbnailURL(id: id))
        guard let (data, _) = try? await URLSession.shared.data(for: request), !data.isEmpty else {
            return nil
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "vi-event-\(id).jpg")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url.path
    }
}
#endif
