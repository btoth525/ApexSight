import AppIntents

/// A camera the user picks when configuring the "ApexSight Camera" widget (iOS 27 A5 —
/// customizable widgets via App Intents). Lives in the shared module so both the app and the
/// widget extension can see it. The candidate list comes from the camera names the app mirrors
/// into the App Group via `SharedSnapshotStore.saveCameraNames(_:)`.
struct WidgetCameraEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Camera"
    static var defaultQuery = WidgetCameraQuery()

    /// The Frigate camera name (also the entity id).
    var id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: Self.titleize(id)))
    }

    static func titleize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

/// Supplies the camera choices for the widget's edit screen, read from App-Group storage so the
/// picker works without launching the app.
struct WidgetCameraQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetCameraEntity] {
        identifiers.map { WidgetCameraEntity(id: $0) }
    }

    func suggestedEntities() async throws -> [WidgetCameraEntity] {
        SharedSnapshotStore.loadCameraNames().map { WidgetCameraEntity(id: $0) }
    }

    func defaultResult() async -> WidgetCameraEntity? {
        SharedSnapshotStore.loadCameraNames().first.map { WidgetCameraEntity(id: $0) }
    }
}

/// The widget's configuration: which camera to show. Backed by an App Intent so the user edits it
/// inline from the widget (long-press → Edit Widget).
struct SelectCameraIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Select Camera"
    static var description = IntentDescription("Choose which camera this widget shows a snapshot of.")

    @Parameter(title: "Camera")
    var camera: WidgetCameraEntity?

    init() {}
    init(camera: WidgetCameraEntity?) { self.camera = camera }
}
