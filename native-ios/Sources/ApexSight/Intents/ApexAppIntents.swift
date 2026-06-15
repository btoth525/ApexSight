import AppIntents
import SwiftUI
import UIKit

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

    var body: some View {
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
            view: AlertSnippetView(title: "\(subject) • \(camera)", subtitle: ago, imagePath: latest.imageURL?.path)
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

struct OpenCameraIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Camera"
    static var description = IntentDescription("Opens a specific camera's live view in ApexSight.")
    static var openAppWhenRun = true

    @Parameter(title: "Camera")
    var camera: CameraEntity

    func perform() async throws -> some IntentResult {
        if let encoded = camera.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            UserDefaults(suiteName: ApexAppGroup.identifier)?
                .set("apex://camera?name=\(encoded)", forKey: "apex.pendingIntentLink")
        }
        return .result()
    }
}

/// A camera the user can pick in a Shortcut / Siri ("Show Front Door").
struct CameraEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Camera"
    static var defaultQuery = CameraQuery()

    var id: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: AlertPhrasing.titleize(id)))
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
