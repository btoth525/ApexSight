import AppIntents
import Foundation

/// A camera event exposed to the system (Visual Intelligence results, Siri, Shortcuts). Mirrors
/// `CameraEntity`: a lightweight value with a `DisplayRepresentation` and an `OpenIntent` that
/// routes through the existing `apex://event?id=…` deep link (the same one `SpotlightIndexer` uses).
struct EventEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Camera Event"
    static var defaultQuery = EventQuery()

    var id: String
    var camera: String
    var label: String
    var subLabel: String?
    var when: Date?
    /// Local cached thumbnail (Frigate needs auth, so results carry a pre-fetched file path
    /// rather than a remote URL the system can't authenticate).
    var thumbnailPath: String?

    init(id: String, camera: String, label: String, subLabel: String? = nil,
         when: Date? = nil, thumbnailPath: String? = nil) {
        self.id = id
        self.camera = camera
        self.label = label
        self.subLabel = subLabel
        self.when = when
        self.thumbnailPath = thumbnailPath
    }

    init(event: FrigateEvent, thumbnailPath: String? = nil) {
        self.init(
            id: event.id,
            camera: event.camera,
            label: event.label,
            subLabel: event.subLabel,
            when: event.startTime.map { Date(timeIntervalSince1970: $0) },
            thumbnailPath: thumbnailPath
        )
    }

    private var subject: String { titleize(subLabel ?? label) }

    var displayRepresentation: DisplayRepresentation {
        let title = LocalizedStringResource(stringLiteral: "\(subject) · \(titleize(camera))")
        let ago = when.map(Self.relative) ?? "earlier"
        let subtitle = LocalizedStringResource(stringLiteral: ago)
        if let thumbnailPath, FileManager.default.fileExists(atPath: thumbnailPath) {
            return DisplayRepresentation(
                title: title, subtitle: subtitle,
                image: DisplayRepresentation.Image(url: URL(fileURLWithPath: thumbnailPath))
            )
        }
        return DisplayRepresentation(title: title, subtitle: subtitle)
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// Resolves event ids back to entities (for the OpenIntent round-trip / Siri).
struct EventQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [EventEntity] {
        guard let session = KeychainStore().loadSession() else { return [] }
        let client = FrigateClient(session: session)
        var results: [EventEntity] = []
        for id in identifiers {
            if let event = try? await client.event(id: id) {
                results.append(EventEntity(event: event))
            }
        }
        return results
    }
}

/// Opens a specific event's detail in ApexSight — used when the user taps an event surfaced by
/// Visual Intelligence or Siri.
struct OpenEventIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open Camera Event"
    static var description = IntentDescription("Opens a camera event in ApexSight.")

    @Parameter(title: "Event")
    var target: EventEntity

    init() {}
    init(target: EventEntity) { self.target = target }

    func perform() async throws -> some IntentResult {
        if let encoded = target.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            UserDefaults(suiteName: ApexAppGroup.identifier)?
                .set("apex://event?id=\(encoded)", forKey: "apex.pendingIntentLink")
        }
        return .result()
    }
}
