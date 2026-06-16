import AppIntents
import SwiftUI
import UIKit
import CoreSpotlight
import UniformTypeIdentifiers

// MARK: - Phrasing helpers

private enum AlertPhrasing {
    static func titleize(_ s: String) -> String {
        s.replacingOccurrences(of: "_", with: " ").capitalized
    }

    /// "Person" / "Maya (face)" — a short spoken subject for an alert.
    static func subject(for alert: SharedAlert) -> String {
        if let sub = alert.subLabel, !sub.isEmpty {
            return titleize(sub)
        }
        return titleize(alert.label)
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Snippet view (shown inline by Siri / Shortcuts)

private struct AlertSnippetView: View {
    let title: String
    let subtitle: String
    let imagePath: String?
    var camera: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let imagePath, let ui = UIImage(contentsOfFile: imagePath) {
                    Image(uiImage: ui)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.gray.opacity(0.25))
                        .frame(width: 72, height: 72)
                        .overlay { Image(systemName: "video.slash").foregroundStyle(.secondary) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            // Interactive snippet buttons (iOS 26) — act without opening the app.
            if let camera {
                HStack(spacing: 10) {
                    Button(intent: ApexOpenCameraIntent(camera: camera)) {
                        Label("View Live", systemImage: "video.fill")
                    }
                    Button(intent: ApexSnoozeIntent()) {
                        Label("Snooze", systemImage: "moon.zzz.fill")
                    }
                }
                .buttonStyle(.bordered)
                .font(.subheadline.weight(.semibold))
            }
        }
        .padding(10)
    }
}

// MARK: - Latest alert ("Hey Siri, anyone at the front door?")

struct LatestAlertIntent: AppIntent {
    static var title: LocalizedStringResource = "Latest Camera Alert"
    static var description = IntentDescription("Tells you the most recent camera alert.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard let latest = SharedSnapshotStore.loadLatestAlert() else {
            return .result(
                dialog: "No camera alerts yet.",
                view: AlertSnippetView(title: "All quiet", subtitle: "No recent alerts", imagePath: nil)
            )
        }
        let alert = latest.alert
        let subject = AlertPhrasing.subject(for: alert)
        let camera = AlertPhrasing.titleize(alert.camera)
        let ago = AlertPhrasing.relative(alert.when)
        let spoken = "\(subject) at \(camera), \(ago)."
        return .result(
            dialog: IntentDialog(stringLiteral: spoken),
            view: AlertSnippetView(title: "\(subject) • \(camera)", subtitle: ago, imagePath: latest.imageURL?.path, camera: alert.camera)
        )
    }
}

// MARK: - Recent activity summary

struct RecentActivityIntent: AppIntent {
    static var title: LocalizedStringResource = "Recent Camera Activity"
    static var description = IntentDescription("Summarizes the most recent camera alerts.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let recent = SharedSnapshotStore.loadRecentAlerts().alerts
        guard !recent.isEmpty else {
            return .result(dialog: "No recent camera activity.")
        }
        let top = recent.prefix(3).map { alert in
            "\(AlertPhrasing.subject(for: alert)) at \(AlertPhrasing.titleize(alert.camera))"
        }
        let summary = top.joined(separator: ", ")
        let count = recent.count
        return .result(dialog: IntentDialog(stringLiteral: "\(count) recent alerts. Most recent: \(summary)."))
    }
}

// MARK: - Open app to cameras

struct ShowLiveCamerasIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Live Cameras"
    static var description = IntentDescription("Opens the live cameras in ApexSight.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        // Opening the app lands on the Cameras tab; no deep link needed.
        return .result()
    }
}

// MARK: - Open a specific camera

/// OpenIntent so tapping a camera in Spotlight (or picking one in Siri/Shortcuts)
/// opens that camera's live view.
struct OpenCameraIntent: OpenIntent {
    static var title: LocalizedStringResource = "Show Camera"
    static var description = IntentDescription("Opens a specific camera's live view in ApexSight.")

    @Parameter(title: "Camera")
    var target: CameraEntity

    init() {}
    init(target: CameraEntity) { self.target = target }

    func perform() async throws -> some IntentResult {
        if let encoded = target.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            UserDefaults(suiteName: ApexAppGroup.identifier)?
                .set("apex://camera?name=\(encoded)", forKey: "apex.pendingIntentLink")
        }
        return .result()
    }
}

/// A camera the user can pick in a Shortcut / Siri ("Show Front Door"), and that
/// gets indexed into Spotlight so typing "front door" opens it.
struct CameraEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Camera"
    static var defaultQuery = CameraQuery()

    var id: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: AlertPhrasing.titleize(id)),
            subtitle: "Camera"
        )
    }
}

@available(iOS 18.0, *)
extension CameraEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let set = CSSearchableItemAttributeSet(contentType: .content)
        set.displayName = AlertPhrasing.titleize(id)
        set.contentDescription = "ApexSight camera"
        set.keywords = ["camera", "apexsight", "frigate", AlertPhrasing.titleize(id)]
        return set
    }
}

struct CameraQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [CameraEntity] {
        identifiers.map(CameraEntity.init(id:))
    }

    func suggestedEntities() async throws -> [CameraEntity] {
        SharedSnapshotStore.loadCameraNames().map(CameraEntity.init(id:))
    }
}

// MARK: - Chainable intents (return values so the new Siri can branch / chain)

struct CheckCameraIntent: AppIntent {
    static var title: LocalizedStringResource = "Check Camera"
    static var description = IntentDescription("Checks a camera for recent activity, and answers with a snapshot.")
    static var openAppWhenRun = false

    @Parameter(title: "Camera")
    var camera: CameraEntity

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Bool> {
        let name = camera.id
        let display = AlertPhrasing.titleize(name)
        guard let session = KeychainStore().loadSession() else {
            return .result(value: false, dialog: "I couldn't reach your cameras.")
        }
        let client = FrigateClient(session: session)
        let since = Date().addingTimeInterval(-15 * 60)
        let events = (try? await client.events(camera: name, after: since, limit: 5)) ?? []
        let active = !events.isEmpty

        let dialog: String
        if active, let first = events.first {
            let subject = AlertPhrasing.titleize(first.subLabel ?? first.label)
            dialog = "Yes — \(subject) at \(display) recently."
        } else {
            dialog = "Nothing at \(display) in the last 15 minutes."
        }
        // Returns a Bool so the new Siri can branch: "if true, turn on the porch light…"
        return .result(value: active, dialog: IntentDialog(stringLiteral: dialog))
    }
}

struct WhoIsHomeIntent: AppIntent {
    static var title: LocalizedStringResource = "Who's Home"
    static var description = IntentDescription("Lists the recognized people seen recently.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[String]> {
        guard let session = KeychainStore().loadSession() else {
            return .result(value: [], dialog: "I couldn't reach your cameras.")
        }
        let client = FrigateClient(session: session)
        let since = Date().addingTimeInterval(-60 * 60)
        let events = (try? await client.events(label: "person", after: since, limit: 50)) ?? []
        let names = Array(Set(events.compactMap(\.recognizedFace))).sorted()
        let dialog = names.isEmpty
            ? "No recognized people in the last hour."
            : "Recently seen: \(names.map(AlertPhrasing.titleize).joined(separator: ", "))."
        return .result(value: names, dialog: IntentDialog(stringLiteral: dialog))
    }
}

// MARK: - Snooze / resume alerts

enum SnoozeDuration: String, AppEnum {
    case fifteenMinutes
    case oneHour
    case fourHours
    case eightHours

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Snooze Duration"
    static var caseDisplayRepresentations: [SnoozeDuration: DisplayRepresentation] = [
        .fifteenMinutes: "15 minutes",
        .oneHour: "1 hour",
        .fourHours: "4 hours",
        .eightHours: "8 hours"
    ]

    var seconds: TimeInterval {
        switch self {
        case .fifteenMinutes: return 15 * 60
        case .oneHour: return 60 * 60
        case .fourHours: return 4 * 60 * 60
        case .eightHours: return 8 * 60 * 60
        }
    }
}

struct SnoozeAlertsIntent: AppIntent {
    static var title: LocalizedStringResource = "Snooze Camera Alerts"
    static var description = IntentDescription("Mutes all ApexSight notifications for a while.")
    static var openAppWhenRun = false

    @Parameter(title: "For how long", default: .oneHour)
    var duration: SnoozeDuration

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let until = Date().addingTimeInterval(duration.seconds)
        GlobalSnooze.snooze(until: until)
        let time = until.formatted(date: .omitted, time: .shortened)
        return .result(dialog: IntentDialog(stringLiteral: "Okay, camera alerts are snoozed until \(time)."))
    }
}

struct ResumeAlertsIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Camera Alerts"
    static var description = IntentDescription("Turns ApexSight notifications back on.")
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        GlobalSnooze.clear()
        return .result(dialog: "Camera alerts are back on.")
    }
}

// MARK: - Shortcuts (the Siri phrases)

struct ApexShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LatestAlertIntent(),
            phrases: [
                "What's the latest alert in \(.applicationName)",
                "Anyone at my door in \(.applicationName)",
                "\(.applicationName) latest alert"
            ],
            shortTitle: "Latest Alert",
            systemImageName: "bell.badge"
        )
        AppShortcut(
            intent: RecentActivityIntent(),
            phrases: [
                "What's happening on my cameras in \(.applicationName)",
                "\(.applicationName) recent activity"
            ],
            shortTitle: "Recent Activity",
            systemImageName: "clock"
        )
        AppShortcut(
            intent: WhoIsHomeIntent(),
            phrases: [
                "Who's home in \(.applicationName)",
                "Who does \(.applicationName) see"
            ],
            shortTitle: "Who's Home",
            systemImageName: "person.2.fill"
        )
        AppShortcut(
            intent: CheckCameraIntent(),
            phrases: [
                "Check the \(\.$camera) in \(.applicationName)",
                "Is anyone at the \(\.$camera) in \(.applicationName)"
            ],
            shortTitle: "Check Camera",
            systemImageName: "video.badge.checkmark"
        )
        AppShortcut(
            intent: ShowLiveCamerasIntent(),
            phrases: [
                "Show my cameras in \(.applicationName)",
                "Open \(.applicationName) cameras"
            ],
            shortTitle: "Live Cameras",
            systemImageName: "video"
        )
        AppShortcut(
            intent: SnoozeAlertsIntent(),
            phrases: [
                "Snooze \(.applicationName) alerts",
                "Mute my cameras in \(.applicationName)"
            ],
            shortTitle: "Snooze Alerts",
            systemImageName: "moon.zzz"
        )
        AppShortcut(
            intent: ResumeAlertsIntent(),
            phrases: [
                "Resume \(.applicationName) alerts",
                "Turn my camera alerts back on in \(.applicationName)"
            ],
            shortTitle: "Resume Alerts",
            systemImageName: "bell"
        )
    }
}
