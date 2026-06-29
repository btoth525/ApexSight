import AppIntents
import ActivityKit
import Foundation

// Action intents that live in the shared layer so they can be invoked from the main
// app, the widget (interactive buttons), and Control Center / Lock Screen controls.
// They touch only app-group state (GlobalSnooze) or stash a pending deep link, so
// they run correctly in any of those processes.

@available(iOS 17.0, *)
struct ApexSnoozeIntent: AppIntent {
    static var title: LocalizedStringResource = "Snooze Camera Alerts"
    static var description = IntentDescription("Mute ApexSight alerts for an hour.")

    func perform() async throws -> some IntentResult {
        GlobalSnooze.snooze(until: Date().addingTimeInterval(60 * 60))
        await SharedRelayGate.syncCurrent()
        return .result()
    }
}

@available(iOS 17.0, *)
struct ApexResumeIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Camera Alerts"
    static var description = IntentDescription("Turn ApexSight alerts back on.")

    func perform() async throws -> some IntentResult {
        GlobalSnooze.clear()
        await SharedRelayGate.syncCurrent()
        return .result()
    }
}

/// Dismisses the current incident Live Activity from its own "Dismiss" button — runs
/// in the widget process and ends the activity immediately so it gets out of the way.
@available(iOS 17.0, *)
struct ApexDismissIncidentIntent: AppIntent {
    static var title: LocalizedStringResource = "Dismiss Alert"
    static var description = IntentDescription("Clear the current camera alert from the Lock Screen / Dynamic Island.")

    func perform() async throws -> some IntentResult {
        for activity in Activity<IncidentActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        return .result()
    }
}

@available(iOS 17.0, *)
struct ApexOpenAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Open ApexSight"
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult { .result() }
}

// MARK: - Arm / Disarm

@available(iOS 17.0, *)
enum ApexArmModeAppEnum: String, AppEnum {
    case disarmed, home, away, night

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Security Mode"
    static var caseDisplayRepresentations: [ApexArmModeAppEnum: DisplayRepresentation] = [
        .disarmed: "Disarmed",
        .home: "Home",
        .away: "Away",
        .night: "Night"
    ]

    var core: ArmMode { ArmMode(rawValue: rawValue) ?? .away }
}

@available(iOS 17.0, *)
struct ApexSetArmModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Security Mode"
    static var description = IntentDescription("Arm or disarm ApexSight (Home, Away, Night, or Disarmed).")

    @Parameter(title: "Mode")
    var mode: ApexArmModeAppEnum

    func perform() async throws -> some IntentResult & ProvidesDialog {
        ArmStateStore.mode = mode.core
        await SharedRelayGate.syncCurrent()
        return .result(dialog: IntentDialog(stringLiteral: "ApexSight is now \(mode.core.title)."))
    }
}

/// Control Center toggle backing intent: on = Away, off = Disarmed.
@available(iOS 18.0, *)
struct ApexArmToggleIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Arm ApexSight"

    @Parameter(title: "Armed")
    var value: Bool

    func perform() async throws -> some IntentResult {
        ArmStateStore.mode = value ? .away : .disarmed
        await SharedRelayGate.syncCurrent()
        return .result()
    }
}

// MARK: - Focus filter (mute alerts while a Focus is active)

@available(iOS 16.0, *)
struct ApexFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "ApexSight Alerts"
    static var description = IntentDescription("Mute ApexSight camera alerts while this Focus is on.")

    @Parameter(title: "Mute camera alerts", default: true)
    var muteAlerts: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: muteAlerts ? "Mute ApexSight alerts" : "ApexSight alerts on")
    }

    func perform() async throws -> some IntentResult {
        if muteAlerts {
            // Long snooze that the matching Focus keeps refreshing while active.
            GlobalSnooze.snooze(until: Date().addingTimeInterval(8 * 60 * 60))
        } else {
            GlobalSnooze.clear()
        }
        await SharedRelayGate.syncCurrent()
        return .result()
    }
}

@available(iOS 17.0, *)
struct ApexOpenCameraIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Camera"
    static var description = IntentDescription("Open a camera's live view in ApexSight.")
    static var openAppWhenRun = true

    @Parameter(title: "Camera")
    var camera: String

    init() {}
    init(camera: String) { self.camera = camera }

    func perform() async throws -> some IntentResult {
        let name = camera.trimmingCharacters(in: .whitespaces)
        if let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            UserDefaults(suiteName: ApexAppGroup.identifier)?
                .set("apex://camera?name=\(encoded)", forKey: "apex.pendingIntentLink")
        }
        return .result()
    }
}
